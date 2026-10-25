"""Disposable Linux-container tests only: real sshd, Mosh server and tmux.

Never invoked by setup. Run as root with VPS_SETUP_SSH_TEST_CONTAINER=1 in CI's
throwaway Ubuntu container; creates test accounts and listens only on loopback.
"""
import importlib.util
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('startup', ROOT / 'tests/test-shell-startup.py')
startup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(startup)


def run(*args, **kwargs):
    return subprocess.run(args, capture_output=True, text=True, check=True, timeout=30, **kwargs)


class SSHStartup(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if os.geteuid() != 0 or os.environ.get('VPS_SETUP_SSH_TEST_CONTAINER') != '1':
            raise RuntimeError('Run only in the disposable SSH test container')
        if not os.environ.get('NVM_TEST_SCRIPT'):
            raise RuntimeError('Source tests/prepare-nvm-test.sh first')
        cls.tmp = tempfile.TemporaryDirectory(prefix='vps-ssh-')
        cls.addClassCleanup(cls.tmp.cleanup)
        cls.base = Path(cls.tmp.name)
        cls.base.chmod(0o755)
        cls.users = {}
        for shell in ['bash', 'zsh']:
            user = 'vps' + shell + str(os.getpid())
            run('useradd', '-m', '-s', '/bin/' + shell, user)
            # Unlock the account without enabling any password authentication.
            run('usermod', '-p', '*', user)
            home = Path('/home') / user
            cls.users[shell] = (user, home)
            startup.install_nvm_fixture(home)
            for name in ['codex', 'claude']:
                startup.executable(home / '.local/bin' / name, f'echo {name}-ready')
            startup.executable(home / '.bun/bin/bun', 'echo bun-ready')
            (home / '.bashrc').write_text(
                '# Existing guarded rc\ncase $- in *i*) ;; *) return ;; esac\n')
            run('chown', '-R', user + ':' + user, str(home))
            run('runuser', '-u', user, '--', 'env', 'HOME=' + str(home),
                'PATH=/usr/bin:/bin', 'NVM_DIR=' + str(home / '.nvm'),
                '/bin/bash', str(ROOT / 'setup.sh'), '--select', 'shortcut,shell', '--yes')
        for name in ['host', 'client']:
            run('ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(cls.base / name))
        for user, home in cls.users.values():
            ssh_dir = home / '.ssh'
            ssh_dir.mkdir(mode=0o700)
            authorized = ssh_dir / 'authorized_keys'
            authorized.write_text((cls.base / 'client.pub').read_text())
            authorized.chmod(0o600)
            run('chown', '-R', user + ':' + user, str(ssh_dir))
        with socket.socket() as s:
            s.bind(('127.0.0.1', 0))
            cls.port = s.getsockname()[1]
        (cls.base / 'known_hosts').write_text(
            f'[127.0.0.1]:{cls.port} ' + (cls.base / 'host.pub').read_text())
        config = cls.base / 'sshd_config'
        config.write_text(f'''Port {cls.port}
ListenAddress 127.0.0.1
HostKey {cls.base}/host
PidFile {cls.base}/sshd.pid
AuthorizedKeysFile .ssh/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
AuthenticationMethods publickey
UsePAM no
PermitRootLogin no
PrintMotd no
PrintLastLog no
AllowUsers {' '.join(u for u, _ in cls.users.values())}
LogLevel ERROR
''')
        Path('/run/sshd').mkdir(exist_ok=True)
        cls.server = subprocess.Popen(['/usr/sbin/sshd', '-D', '-e', '-f', str(config)],
                                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        cls.addClassCleanup(cls.stop_server)
        cls.ssh = ['ssh', '-F', '/dev/null', '-p', str(cls.port), '-i', str(cls.base / 'client'),
                   '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes',
                   '-o', 'StrictHostKeyChecking=yes', '-o', 'ConnectTimeout=2',
                   '-o', 'UserKnownHostsFile=' + str(cls.base / 'known_hosts')]
        for _ in range(50):
            with socket.socket() as s:
                if s.connect_ex(('127.0.0.1', cls.port)) == 0: break
            if cls.server.poll() is not None: raise RuntimeError('Test sshd exited')
            time.sleep(0.1)
        else: raise RuntimeError('Test sshd did not start')

    @classmethod
    def stop_server(cls):
        cls.server.terminate()
        cls.server.wait(timeout=10)
        for user, _ in cls.users.values():
            subprocess.run(['pkill', '-u', user, '-x', 'mosh-server'], check=False)
            subprocess.run(['runuser', '-u', user, '--', 'tmux', 'kill-server'],
                           capture_output=True, check=False)

    def remote(self, shell, command):
        try:
            return run(*self.ssh, self.users[shell][0] + '@127.0.0.1', command)
        except subprocess.CalledProcessError as exc:
            self.fail(f'SSH command failed ({exc.returncode}): {exc.stderr}')

    def test_remote_tools_and_silent_startup(self):
        for shell in self.users:
            with self.subTest(shell=shell):
                empty = self.remote(shell, ':')
                self.assertEqual((empty.stdout, empty.stderr), ('', ''))
                r = self.remote(shell, 'codex; claude; bun; node --version; npm --version; '
                                'npx --version; typeset -f t >/dev/null && echo ready')
                self.assertEqual(r.stdout.splitlines(), ['codex-ready', 'claude-ready',
                                 'bun-ready', 'v22.0.0', 'npm-v22.0.0', 'npx-v22.0.0', 'ready'])
                self.assertEqual(r.stderr, '')
                r = self.remote(shell, shell + ' -lc "node --version"')
                self.assertEqual(r.stdout, 'v22.0.0\n')

    def test_real_mosh_server_launch(self):
        for shell in self.users:
            with self.subTest(shell=shell):
                r = self.remote(shell, 'LANG=C.UTF-8 mosh-server new -c 256')
                self.assertTrue(re.search(r'^MOSH CONNECT \d+ \S+', r.stdout, re.M),
                                'Mosh server did not emit its startup protocol')

    def test_real_tmux_shortcut_over_ssh(self):
        for shell, (user, home) in self.users.items():
            with self.subTest(shell=shell):
                p = subprocess.Popen(self.ssh + ['-tt', user + '@127.0.0.1', 't smoke'],
                                     env=dict(os.environ, TERM='xterm-256color'),
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                try:
                    for _ in range(100):
                        exists = subprocess.run(['runuser', '-u', user, '--', 'tmux',
                                                 'has-session', '-t', '=smoke'], capture_output=True)
                        if exists.returncode == 0: break
                        if p.poll() is not None:
                            _, stderr = p.communicate()
                            self.fail('SSH shortcut exited before creating tmux session: ' + stderr)
                        time.sleep(0.1)
                    else: self.fail('Shortcut did not create a tmux session')
                    r = run('runuser', '-u', user, '--', 'tmux', 'display-message',
                            '-p', '-t', '=smoke', '#{pane_current_path}')
                    self.assertEqual(r.stdout.strip(), str(home / 'workspace'))
                    run('runuser', '-u', user, '--', 'tmux', 'kill-session', '-t', '=smoke')
                    p.communicate(timeout=10)
                    self.assertEqual(p.returncode, 0)
                finally:
                    if p.poll() is None:
                        p.terminate()
                    p.communicate(timeout=10)


if __name__ == '__main__':
    unittest.main(verbosity=2)
