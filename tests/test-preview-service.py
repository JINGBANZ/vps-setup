"""Preview setup safety and real static-server behavior; no host provisioning."""
import importlib.util
import io
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import tarfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('preview', ROOT / 'lib/preview_service.py')
preview = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preview)


class PreviewSetup(unittest.TestCase):
    def test_user_local_and_symlinked_tailscale_apps_are_recognized(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            cli = home / 'Applications/Tailscale.app/Contents/MacOS/Tailscale'
            cli.parent.mkdir(parents=True)
            cli.touch()
            with patch.object(preview.shutil, 'which', return_value=None), \
                 patch.object(Path, 'is_file', autospec=True, side_effect=lambda p: p == cli):
                self.assertEqual(preview.find_tailscale(home), (str(cli), True))
            symlink = home / 'tailscale'
            symlink.symlink_to(cli)
            with patch.object(preview.shutil, 'which', return_value=str(symlink)):
                self.assertEqual(preview.find_tailscale(home), (str(symlink), True))

    def test_existing_routes_are_preserved_or_refused(self):
        unrelated = {'Web': {'mini.test.ts.net:443': {'Handlers': {'/': {'Proxy': 'http://127.0.0.1:9000'}}}}}
        before = json.dumps(unrelated)
        preview.check_routes(unrelated, 'mini.test.ts.net', False)
        self.assertEqual(json.dumps(unrelated), before)
        ours = {'Web': {'mini.test.ts.net:8443': {'Handlers': {'/': {'Proxy': 'http://127.0.0.1:8787'}}}},
                'TCP': {'8443': {'HTTPS': True}}}
        preview.check_routes(ours, 'mini.test.ts.net', True)
        preview.check_routes(ours, 'mini.test.ts.net', True, required=True)
        with self.assertRaisesRegex(ValueError, 'did not retain'):
            preview.check_routes({}, 'mini.test.ts.net', True, required=True)
        with self.assertRaises(ValueError):
            preview.check_routes(ours, 'mini.test.ts.net', False)
        for changed in [dict(ours, AllowFunnel={'mini.test.ts.net:8443': True}),
                        dict(ours, TCP={'8443': {'TCPForward': 'localhost:1'}}),
                        {'TCP': {'8443': {'HTTPS': True}}}]:
            with self.assertRaises(ValueError):
                preview.check_routes(changed, 'mini.test.ts.net', True)
        ours['Web']['mini.test.ts.net:8443']['Handlers']['/other'] = {'Text': 'keep me'}
        with self.assertRaises(ValueError):
            preview.check_routes(ours, 'mini.test.ts.net', True)

    def test_skill_collision_is_not_overwritten(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            canonical = home / 'managed/skill'
            preview.check_skill_targets(home, canonical)
            target = preview.skill_targets(home)[0]
            target.parent.mkdir(parents=True)
            target.symlink_to(canonical)
            preview.check_skill_targets(home, canonical)
            target.unlink()
            target.mkdir()
            (target / 'SKILL.md').write_text('personal skill')
            with self.assertRaises(ValueError):
                preview.check_skill_targets(home, canonical)
            self.assertEqual((target / 'SKILL.md').read_text(), 'personal skill')

    def test_public_routes_cannot_expose_the_reserved_preview_backend(self):
        address = 'mini.test.ts.net:443'
        for target in ['http://127.0.0.1:8787', 'http://localhost:8787/task/', 'http://127.0.0.1:9000']:
            config = {'AllowFunnel': {address: True}, 'TCP': {'443': {'HTTPS': True}},
                      'Web': {address: {'Handlers': {'/': {'Proxy': target}}}}}
            for routes in [config, {'Foreground': {'session': config}}]:
                with self.subTest(target=target, routes=routes):
                    if target.endswith(':9000'):
                        preview.check_routes(routes, 'mini.test.ts.net', False)
                    else:
                        with self.assertRaisesRegex(ValueError, 'Funnel route targets'):
                            preview.check_routes(routes, 'mini.test.ts.net', False)
        tcp = {'AllowFunnel': {address: True},
               'TCP': {'443': {'TCPForward': '127.0.0.1:8787', 'TerminateTLS': 'mini.test.ts.net'}}}
        with self.assertRaisesRegex(ValueError, 'Funnel route targets'):
            preview.check_routes(tcp, 'mini.test.ts.net', False)

    def test_config_writes_are_private_and_refuse_symlinks(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'config.json'
            preview.write_user(path, b'{}')
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            path.unlink()
            other = Path(directory) / 'other'
            other.write_text('preserve')
            path.symlink_to(other)
            with self.assertRaises(ValueError):
                preview.write_user(path, b'{}')
            self.assertEqual(other.read_text(), 'preserve')

    def test_installer_registers_discovery_and_preserves_previews_on_rerun(self):
        for system in ['Linux', 'Darwin']:
            with self.subTest(system=system), tempfile.TemporaryDirectory() as directory:
                base = Path(directory)
                home = base / 'home'
                state = base / 'state'
                binary = base / 'bin/caddy'
                state_path = '/var/lib/preview-service' if system == 'Linux' else '/Library/Application Support/preview-service'
                paths = {state_path: state, '/usr/local/libexec/preview-service/caddy': binary,
                         '/etc/systemd/system/preview-service.service': base / 'unit',
                         '/Library/LaunchDaemons/' + preview.SERVICE + '.plist': base / 'daemon.plist'}
                routes = {'Web': {'mini.test.ts.net:443': {'Handlers': {'/': {'Text': 'unrelated'}}}}}
                calls = []
                def run(args, privileged=False, **kwargs):
                    args = [str(a) for a in args]
                    calls.append((args, privileged))
                    if args[0] == 'install':
                        target = Path(args[-1])
                        if '-d' in args:
                            target.mkdir(parents=True, exist_ok=True)
                        else:
                            target.write_bytes(Path(args[-2]).read_bytes())
                        target.chmod(int(args[args.index('-m') + 1], 8))
                    elif args[0] == '/fake/tailscale':
                        if args[1:3] == ['status', '--json']:
                            return json.dumps({'BackendState': 'Running', 'Self': {'DNSName': 'mini.test.ts.net.'}})
                        if args[1:4] == ['serve', 'status', '--json']:
                            return json.dumps(routes)
                        self.assertEqual(args[1:], ['serve', '--bg', '--https=8443', '--yes', 'http://127.0.0.1:8787'])
                        routes['Web']['mini.test.ts.net:8443'] = {'Handlers': {'/': {'Proxy': 'http://127.0.0.1:8787'}}}
                        routes['TCP'] = {'8443': {'HTTPS': True}}
                    return ''
                archive = io.BytesIO()
                with tarfile.open(fileobj=archive, mode='w:gz') as tar:
                    info = tarfile.TarInfo('caddy')
                    info.size = 6
                    tar.addfile(info, io.BytesIO(b'binary'))
                account = SimpleNamespace(pw_name='preview', pw_gid=os.getgid())
                with patch.object(preview, 'Path', side_effect=lambda p: paths.get(str(p), Path(p))) as path_type, \
                     patch.object(preview.platform, 'system', return_value=system), \
                     patch.object(preview.platform, 'machine', return_value='x86_64'), \
                     patch.object(preview.shutil, 'which', return_value='/fake/tailscale'), \
                     patch.object(preview, 'run', side_effect=run), \
                     patch.object(preview, 'service_account', return_value=account), \
                     patch.object(preview, 'download', side_effect=lambda url, digest: archive.getvalue() if url.endswith('.tar.gz') else b'skill'), \
                     patch.object(preview, 'SKILL_FILES', {'SKILL.md': 'test', 'scripts/publish.py': 'test'}), \
                     patch.object(preview.socket, 'socket'), \
                     patch.object(preview.subprocess, 'run', return_value=SimpleNamespace(returncode=1)), \
                     patch.object(preview, 'verify_service') as verify:
                    path_type.home.return_value = home
                    preview.install()
                    discovery = home / '.config/vps-setup/preview-service.json'
                    config = json.loads(discovery.read_text())
                    self.assertEqual(config['preview_root'], str(state / 'previews'))
                    self.assertEqual(config['base_url'], 'https://mini.test.ts.net:8443')
                    for target in preview.skill_targets(home):
                        self.assertEqual((target / 'SKILL.md').read_bytes(), b'skill')
                    saved = state / 'previews/existing.html'
                    saved.write_text('preserve')
                    preview.install()
                    self.assertEqual(saved.read_text(), 'preserve')
                    self.assertEqual(routes['Web']['mini.test.ts.net:443'], {'Handlers': {'/': {'Text': 'unrelated'}}})
                    self.assertEqual(verify.call_count, 2)
                    if system == 'Linux':
                        self.assertIn('ProtectSystem=strict', (base / 'unit').read_text())
                        self.assertIn((['systemctl', 'enable', '--now', 'preview-service.service'], True), calls)
                    else:
                        self.assertIn((['launchctl', 'bootstrap', 'system', str(base / 'daemon.plist')], True), calls)
                    discovery.unlink()
                    with patch.object(preview, 'verify_service', side_effect=ValueError('cannot serve')):
                        with self.assertRaisesRegex(ValueError, 'cannot serve'):
                            preview.install()
                    self.assertFalse(discovery.exists())

    @unittest.skipUnless(os.environ.get('PREVIEW_TEST_CADDY'), 'set PREVIEW_TEST_CADDY for the real server smoke test')
    def test_real_caddy_serves_html_without_listing_or_hidden_files(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            root = base / 'previews'
            task = root / 'readable-task'
            task.mkdir(parents=True)
            (task / 'index.html').write_text('<html>preview</html>')
            (task / '.publish.lock').write_text('private')
            with socket.socket() as sock:
                sock.bind(('127.0.0.1', 0))
                port = sock.getsockname()[1]
            config = base / 'Caddyfile'
            config.write_text(preview.caddy_config(root).replace('8787', str(port)))
            binary = os.environ['PREVIEW_TEST_CADDY']
            subprocess.run([binary, 'validate', '--config', str(config), '--adapter', 'caddyfile'], check=True, capture_output=True)
            with (base / 'log').open('w+') as log:
                proc = subprocess.Popen([binary, 'run', '--config', str(config), '--adapter', 'caddyfile'], stdout=log, stderr=log)
                try:
                    for _ in range(50):
                        try:
                            with urllib.request.urlopen('http://127.0.0.1:%d/readable-task/' % port, timeout=1) as response:
                                self.assertEqual(response.read(), b'<html>preview</html>')
                                self.assertEqual(response.headers['X-Content-Type-Options'], 'nosniff')
                                break
                        except OSError:
                            if proc.poll() is not None:
                                log.seek(0)
                                self.fail(log.read())
                            time.sleep(0.1)
                    else:
                        self.fail('Caddy did not start')
                    forwarded = urllib.request.Request('http://127.0.0.1:%d/readable-task/' % port,
                                                       headers={'Host': 'mini.test.ts.net:8443'})
                    with urllib.request.urlopen(forwarded, timeout=1) as response:
                        self.assertEqual(response.read(), b'<html>preview</html>')
                    for suffix in ['/', '/readable-task/.publish.lock', '/readable-task/%2epublish.lock', '/Caddyfile']:
                        with self.subTest(path=suffix), self.assertRaises(urllib.error.HTTPError) as error:
                            urllib.request.urlopen('http://127.0.0.1:%d%s' % (port, suffix), timeout=1)
                        self.assertEqual(error.exception.code, 404)
                finally:
                    proc.terminate()
                    proc.wait(timeout=10)


if __name__ == '__main__':
    unittest.main()
