#!/usr/bin/env python3
"""Install the explicitly selected, host-local Preview service."""
import argparse
import grp
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import plistlib
import pwd
import shutil
import socket
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.parse
import urllib.request

CADDY_VERSION = '2.11.7'
CADDY_SHA256 = {
    ('Linux', 'x86_64'): '727b91701a392de6ebc5027509f548bf39979e5216340d0faed8fa5e69c84f8b',
    ('Linux', 'aarch64'): 'd8fc6d179a5d283028a472a5618564f6ad8a86fed513e64f032b3b0b7cc45e42',
    ('Darwin', 'x86_64'): '110c53e5c093e4cfce6eda787f94f23bef913c309f620fab26b4f678031841ad',
    ('Darwin', 'arm64'): 'cda3030e5d5b13eb9f0b6fb541037f633bddd958c070c5f561d7a5cccb581665',
}
SKILL_REVISION = 'e7fdbce9b80cd3a7d0153818e2bb2c73208b15f9'
SKILL_FILES = {
    'SKILL.md': 'c4c81ce5bae1f381843c2cdd16eb3f58f0c2fc5bc9e9f8b7682e5ae8b7d64db6',
    'agents/openai.yaml': '18b594202ba7f5895af46a487c43f26798111bc29b8f8a3047a19e6457e1855f',
    'scripts/publish.py': 'e3f561d1f6214b60e4293fd834886b128ee5944eb93673d80368629673ac2b82',
}
LOCAL_PORT = 8787
HTTPS_PORT = 8443
SERVICE = 'org.jingbanz.preview-service'


def run(args, privileged=False, capture_output=True, **kwargs):
    prefix = ['sudo'] if privileged and os.geteuid() != 0 else []
    output = subprocess.PIPE if capture_output else None
    result = subprocess.run(prefix + [str(a) for a in args], check=True, text=True,
                            stdout=output, stderr=output, **kwargs)
    return (result.stdout or '').strip()


def download(url, digest):
    with urllib.request.urlopen(url, timeout=60) as response:
        content = response.read()
    if hashlib.sha256(content).hexdigest() != digest:
        raise ValueError('Download checksum mismatch: ' + url)
    return content


def caddy_binary(system, machine):
    os_name = 'mac' if system == 'Darwin' else 'linux'
    arch = 'amd64' if machine == 'x86_64' else 'arm64'
    filename = 'caddy_%s_%s_%s.tar.gz' % (CADDY_VERSION, os_name, arch)
    archive = download('https://github.com/caddyserver/caddy/releases/download/v%s/%s' % (CADDY_VERSION, filename),
                       CADDY_SHA256[(system, machine)])
    with tarfile.open(fileobj=io.BytesIO(archive), mode='r:gz') as tar:
        member = tar.getmember('caddy')
        if not member.isfile():
            raise ValueError('Caddy archive did not contain a regular binary')
        return tar.extractfile(member).read()


def caddy_config(root):
    return '''{
    admin off
    auto_https off
    persist_config off
}
http://:8787 {
    bind 127.0.0.1
    root * %s
    header {
        X-Content-Type-Options nosniff
        Referrer-Policy no-referrer
        Cache-Control no-store
    }
    @private path_regexp hidden (^|/)\\.
    respond @private 404
    file_server
}
''' % json.dumps(str(root))


def check_public_backends(config):
    for address, enabled in config.get('AllowFunnel', {}).items():
        if not enabled:
            continue
        handlers = config.get('Web', {}).get(address, {}).get('Handlers', {})
        targets = [handler['Proxy'] for handler in handlers.values() if handler.get('Proxy')]
        tcp = config.get('TCP', {}).get(address.rsplit(':', 1)[-1], {})
        if tcp.get('TCPForward'):
            targets.append(tcp['TCPForward'])
        for target in targets:
            upstream = urllib.parse.urlsplit(target if '://' in target else '//' + target)
            if upstream.hostname in ('127.0.0.1', 'localhost') and upstream.port == LOCAL_PORT:
                raise ValueError('Existing Funnel route targets localhost:8787; resolve it manually before setup')
    for foreground in config.get('Foreground', {}).values():
        check_public_backends(foreground)


def check_routes(config, dns, managed, required=False):
    check_public_backends(config)
    for address, enabled in config.get('AllowFunnel', {}).items():
        if address.endswith(':' + str(HTTPS_PORT)) and enabled:
            raise ValueError('Port 8443 has Funnel enabled; resolve it manually before setup')
    handlers = config.get('Web', {})
    matching = {key: value for key, value in handlers.items() if key.endswith(':8443')}
    expected = {dns + ':8443': {'Handlers': {'/': {'Proxy': 'http://127.0.0.1:8787'}}}}
    if matching and (not managed or matching != expected):
        raise ValueError('Tailscale Serve port 8443 is already configured; existing routes were preserved')
    tcp = config.get('TCP', {}).get('8443')
    if tcp and (not matching or tcp != {'HTTPS': True}):
        raise ValueError('Tailscale port 8443 is occupied by a different service')
    if required and (matching != expected or tcp != {'HTTPS': True}):
        raise ValueError('Tailscale did not retain the Preview service HTTPS mapping')


def skill_targets(home):
    return [home / '.agents/skills/preview-service', home / '.claude/skills/preview-service']


def find_tailscale(home):
    executable = shutil.which('tailscale')
    if not executable:
        for bundle in [Path('/Applications/Tailscale.app'), home / 'Applications/Tailscale.app']:
            candidate = bundle / 'Contents/MacOS/Tailscale'
            if candidate.is_file():
                executable = str(candidate)
                break
    if not executable:
        raise ValueError('Install and sign in to Tailscale, then rerun Preview service setup')
    gui = str(Path(executable).resolve()).endswith('/Tailscale.app/Contents/MacOS/Tailscale')
    return executable, gui


def check_skill_targets(home, canonical):
    for target in skill_targets(home):
        if target.is_symlink():
            if target.resolve() != canonical.resolve():
                raise ValueError('Existing skill preserved; resolve conflict: ' + str(target))
        elif target.exists():
            raise ValueError('Existing skill preserved; resolve conflict: ' + str(target))


def write_user(path, content, mode=0o600):
    if path.is_symlink():
        raise ValueError('Refusing to replace symlink: ' + str(path))
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as output:
            os.fchmod(output.fileno(), mode)
            output.write(content)
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def install_file(path, content, mode=0o644):
    if path.is_symlink():
        raise ValueError('Refusing to replace symlink: ' + str(path))
    if (path.exists() and path.read_bytes() == content and path.stat().st_uid == 0
            and path.stat().st_mode & 0o7777 == mode):
        return False
    with tempfile.TemporaryDirectory() as temporary:
        source = Path(temporary) / 'file'
        source.write_bytes(content)
        run(['install', '-d', '-m', '0755', path.parent], privileged=True)
        run(['install', '-o', '0', '-g', '0', '-m', format(mode, 'o'), source, path], privileged=True)
    return True


def verify_service(public, dns):
    # A random file proves the running listener can read this exact served root.
    fd, name = tempfile.mkstemp(prefix='setup-', suffix='.txt', dir=public)
    content = os.urandom(32)
    try:
        with os.fdopen(fd, 'wb') as output:
            os.fchmod(output.fileno(), 0o640)
            output.write(content)
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        url = 'http://127.0.0.1:8787/' + Path(name).name
        request = urllib.request.Request(url, headers={'Host': dns + ':8443'})
        for attempt in range(20):
            try:
                with opener.open(request, timeout=1) as response:
                    if response.status == 200 and response.read(33) == content:
                        return
            except OSError:
                pass
            if attempt < 19:
                time.sleep(0.25)
        raise ValueError('Preview service could not serve its preview folder; check service logs and permissions')
    finally:
        Path(name).unlink()


def service_account(system):
    name = '_vpspreview' if system == 'Darwin' else 'vps-preview'
    try:
        account = pwd.getpwnam(name)
        if account.pw_uid == 0 or account.pw_shell not in ('/usr/sbin/nologin', '/usr/bin/false'):
            raise ValueError('Existing service account is not a non-login account: ' + name)
        return account
    except KeyError:
        pass
    if system == 'Linux':
        run(['useradd', '--system', '--user-group', '--no-create-home', '--home-dir', '/nonexistent',
             '--shell', '/usr/sbin/nologin', name], privileged=True)
    else:
        used = {a.pw_uid for a in pwd.getpwall()} | {g.gr_gid for g in grp.getgrall()}
        identifier = next(i for i in range(499, 399, -1) if i not in used)
        for record, fields in [('Groups', {'PrimaryGroupID': str(identifier)}),
                               ('Users', {'UniqueID': str(identifier), 'PrimaryGroupID': str(identifier),
                                          'UserShell': '/usr/bin/false', 'NFSHomeDirectory': '/var/empty',
                                          'IsHidden': '1', 'RealName': 'Preview service'})]:
            for key, value in fields.items():
                run(['dscl', '.', '-create', '/' + record + '/' + name, key, value], privileged=True)
    return pwd.getpwnam(name)


def systemd_unit(binary, config, account):
    return '''[Unit]
Description=Preview service
After=network.target

[Service]
User=%s
Group=%s
ExecStart=%s run --config %s --adapter caddyfile
Restart=on-failure
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
CapabilityBoundingSet=
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
UMask=0027

[Install]
WantedBy=multi-user.target
''' % (account.pw_name, grp.getgrgid(account.pw_gid).gr_name, binary, config)


def launchd_plist(binary, config, account):
    return plistlib.dumps({'Label': SERVICE, 'ProgramArguments': [str(binary), 'run', '--config', str(config),
                             '--adapter', 'caddyfile'], 'UserName': account.pw_name,
                          'GroupName': grp.getgrgid(account.pw_gid).gr_name,
                          'RunAtLoad': True, 'KeepAlive': True, 'Umask': 0o027})


def activate(system, binary, config, account, changed):
    if system == 'Linux':
        unit = Path('/etc/systemd/system/preview-service.service')
        changed = install_file(unit, systemd_unit(binary, config, account).encode()) or changed
        run(['systemctl', 'daemon-reload'], privileged=True)
        run(['systemctl', 'enable', '--now', 'preview-service.service'], privileged=True)
        if changed:
            run(['systemctl', 'restart', 'preview-service.service'], privileged=True)
        run(['systemctl', 'is-active', '--quiet', 'preview-service.service'])
    else:
        path = Path('/Library/LaunchDaemons/' + SERVICE + '.plist')
        changed = install_file(path, launchd_plist(binary, config, account)) or changed
        loaded = subprocess.run(['sudo', 'launchctl', 'print', 'system/' + SERVICE],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
        if loaded and changed:
            run(['launchctl', 'bootout', 'system/' + SERVICE], privileged=True)
            loaded = False
        if not loaded:
            run(['launchctl', 'enable', 'system/' + SERVICE], privileged=True)
            run(['launchctl', 'bootstrap', 'system', path], privileged=True)
        run(['launchctl', 'print', 'system/' + SERVICE], privileged=True)


def check_installation():
    system = platform.system()
    home = Path.home()
    state = Path('/Library/Application Support/preview-service' if system == 'Darwin' else '/var/lib/preview-service')
    public = state / 'previews'
    canonical = home / '.local/share/vps-setup/preview-service/skill'
    binary = Path('/usr/local/libexec/preview-service/caddy')
    config_path = home / '.config/vps-setup/preview-service.json'
    service_path = Path('/Library/LaunchDaemons/' + SERVICE + '.plist' if system == 'Darwin'
                        else '/etc/systemd/system/preview-service.service')
    for path in [state, public, state / 'owner.json', state / 'Caddyfile', canonical, binary, config_path, service_path]:
        if path.is_symlink():
            raise ValueError('Refusing symlink in managed installation: ' + str(path))
    if json.loads((state / 'owner.json').read_text()) != {'owner_uid': os.getuid()}:
        raise ValueError('Preview service belongs to another user')
    if not public.is_dir() or (state / 'Caddyfile').read_text() != caddy_config(public):
        raise ValueError('Preview folder or Caddy configuration needs repair')
    account = pwd.getpwnam('_vpspreview' if system == 'Darwin' else 'vps-preview')
    if account.pw_uid == 0 or account.pw_shell not in ('/usr/sbin/nologin', '/usr/bin/false'):
        raise ValueError('Preview service account needs repair')
    permissions = public.stat()
    if (permissions.st_uid != os.getuid() or permissions.st_gid != account.pw_gid
            or permissions.st_mode & 0o7777 != 0o2750):
        raise ValueError('Preview folder permissions need repair')
    expected_service = (launchd_plist(binary, state / 'Caddyfile', account) if system == 'Darwin'
                        else systemd_unit(binary, state / 'Caddyfile', account).encode())
    if not service_path.is_file() or service_path.read_bytes() != expected_service:
        raise ValueError('Preview boot service needs repair')
    for path, digest in SKILL_FILES.items():
        if hashlib.sha256((canonical / path).read_bytes()).hexdigest() != digest:
            raise ValueError('Preview publishing skill needs repair or update')
    for target in skill_targets(home):
        if not target.is_symlink() or target.resolve() != canonical.resolve():
            raise ValueError('Preview skill registration needs repair: ' + str(target))
    if run([binary, 'version'], timeout=5).split()[:1] != ['v' + CADDY_VERSION]:
        raise ValueError('Preview Caddy version needs updating')
    if system == 'Darwin':
        service = run(['launchctl', 'print', 'system/' + SERVICE], timeout=5)
        if 'state = running' not in [line.strip() for line in service.splitlines()]:
            raise ValueError('Preview service is not running')
    else:
        run(['systemctl', 'is-active', '--quiet', 'preview-service.service'], timeout=5)
        run(['systemctl', 'is-enabled', '--quiet', 'preview-service.service'], timeout=5)
    tailscale, _ = find_tailscale(home)
    status = json.loads(run([tailscale, 'status', '--json'], timeout=5))
    dns = ((status.get('Self') or {}).get('DNSName') or '').rstrip('.')
    if status.get('BackendState') != 'Running' or not dns.endswith('.ts.net'):
        raise ValueError('Tailscale must be running and signed in')
    if dns not in (status.get('CertDomains') or []):
        raise ValueError('Tailscale HTTPS needs account approval')
    config = {'version': 1, 'preview_root': str(public), 'base_url': 'https://' + dns + ':8443',
              'publisher': str(canonical / 'scripts/publish.py'), 'skill_revision': SKILL_REVISION}
    if json.loads(config_path.read_text()) != config:
        raise ValueError('Preview service discovery needs repair or update')
    check_routes(json.loads(run([tailscale, 'serve', 'status', '--json'], timeout=5)), dns, True, required=True)
    return 'Running and configured: ' + config['base_url']


def install(interactive=False):
    system, machine = platform.system(), platform.machine()
    if (system, machine) not in CADDY_SHA256:
        raise ValueError('Preview service does not support this platform: %s %s' % (system, machine))
    home = Path.home()
    owner = pwd.getpwuid(os.getuid())
    state = Path('/Library/Application Support/preview-service' if system == 'Darwin' else '/var/lib/preview-service')
    public = state / 'previews'
    marker = state / 'owner.json'
    config_path = home / '.config/vps-setup/preview-service.json'
    canonical = home / '.local/share/vps-setup/preview-service/skill'
    binary = Path('/usr/local/libexec/preview-service/caddy')
    server_config = state / 'Caddyfile'
    for path in [state, public, marker, config_path, canonical, binary, server_config]:
        if path.is_symlink():
            raise ValueError('Refusing symlink in managed installation: ' + str(path))
    managed = marker.exists() and json.loads(marker.read_text()) == {'owner_uid': owner.pw_uid}
    if state.exists() and not managed:
        raise ValueError('Preview service directory belongs to another installation or user: ' + str(state))
    check_skill_targets(home, canonical)
    tailscale, gui_tailscale = find_tailscale(home)
    status = json.loads(run([tailscale, 'status', '--json'], timeout=15))
    dns = ((status.get('Self') or {}).get('DNSName') or '').rstrip('.')
    if status.get('BackendState') != 'Running' or not dns.endswith('.ts.net'):
        raise ValueError('Tailscale must be running and signed in with a tailnet DNS name; rerun after sign-in')
    https_ready = dns in (status.get('CertDomains') or [])
    if not https_ready and not interactive:
        raise ValueError('Tailscale HTTPS needs one-time account approval. Rerun setup without --yes '
                         'to approve and continue automatically, or enable HTTPS Certificates at '
                         'https://login.tailscale.com/admin/dns before unattended setup.')
    routes = json.loads(run([tailscale, 'serve', 'status', '--json'], timeout=15))
    check_routes(routes, dns, managed)
    try:
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', LOCAL_PORT))
    except OSError:
        if not managed:
            raise ValueError('Local port 8787 is already in use; existing service was preserved')
    executable = caddy_binary(system, machine)
    if not SKILL_FILES:
        raise ValueError('Skill release is not pinned')
    skill = {path: download('https://raw.githubusercontent.com/JINGBANZ/skills/%s/preview-service/%s' %
                           (SKILL_REVISION, path), digest) for path, digest in SKILL_FILES.items()}
    account = service_account(system)
    run(['install', '-d', '-m', '0755', state], privileged=True)
    install_file(marker, json.dumps({'owner_uid': owner.pw_uid}).encode())
    run(['install', '-d', '-m', '2750', '-o', owner.pw_uid, '-g', account.pw_gid, public], privileged=True)
    changed = install_file(binary, executable, 0o755)
    changed = install_file(server_config, caddy_config(public).encode()) or changed
    run([binary, 'validate', '--config', server_config, '--adapter', 'caddyfile'])
    activate(system, binary, server_config, account, changed)
    verify_service(public, dns)
    if not https_ready:
        print('Tailscale HTTPS needs one-time account approval. Open the link below on your laptop.\n'
              'Certificate issuance publishes this machine\'s DNS name; preview files stay private.\n'
              'Setup will continue automatically after approval. Press Ctrl+C to cancel.', flush=True)
    # The endpoint is fixed: unrelated routes are never reset or replaced.
    run([tailscale, 'serve', '--bg', '--https=8443', '--yes', 'http://127.0.0.1:8787'],
        privileged=not gui_tailscale, capture_output=False,
        timeout=None if interactive and not https_ready else 30)
    check_routes(json.loads(run([tailscale, 'serve', 'status', '--json'], timeout=15)), dns, True, required=True)
    for path, data in skill.items():
        write_user(canonical / path, data, 0o644)
    for target in skill_targets(home):
        target.parent.mkdir(parents=True, exist_ok=True)
        if not target.is_symlink():
            target.symlink_to(canonical, target_is_directory=True)
    config = {'version': 1, 'preview_root': str(public), 'base_url': 'https://' + dns + ':8443',
              'publisher': str(canonical / 'scripts/publish.py'), 'skill_revision': SKILL_REVISION}
    write_user(config_path, (json.dumps(config, indent=2) + '\n').encode())
    print('Preview service configured: ' + config['base_url'])
    print('Preview folder: ' + str(public))
    print('Discovery: ' + str(config_path))
    print('Skill registered for Codex and Claude Code; start a new agent session to discover it.')
    if system == 'Darwin' and gui_tailscale:
        print('Tailscale.app requires a login session; private links resume after Tailscale starts at login.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--interactive', action='store_true', help='allow Tailscale to wait for browser approval')
    mode.add_argument('--check', action='store_true', help='check installed files and local daemon status without changes')
    args = parser.parse_args()
    try:
        if args.check:
            print(check_installation())
        else:
            install(interactive=args.interactive)
    except KeyboardInterrupt:
        print('Preview service cancelled.', file=sys.stderr)
        sys.exit(130)
    except subprocess.CalledProcessError as error:
        print('Preview service: ' + (error.stderr or error.stdout or str(error)), file=sys.stderr)
        sys.exit(1)
    except (OSError, ValueError, KeyError, StopIteration, subprocess.TimeoutExpired) as error:
        print('Preview service: ' + str(error), file=sys.stderr)
        sys.exit(1)
