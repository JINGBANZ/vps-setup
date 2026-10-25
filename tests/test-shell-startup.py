"""Real Bash/Zsh startup and upstream nvm; package provisioning stays isolated."""
import importlib.util
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('fixture', ROOT / 'tests/test-macos-install.py')
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


def executable(path, body):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text('#!/bin/sh\n' + body + '\n')
    path.chmod(0o755)


def install_nvm_fixture(home):
    """Use upstream nvm with two local Node stubs; no download/install at runtime."""
    nvm = home / '.nvm'
    (nvm / 'alias').mkdir(parents=True, exist_ok=True)
    shutil.copyfile(os.environ['NVM_TEST_SCRIPT'], nvm / 'nvm.sh')
    (nvm / 'alias/default').write_text('v22.0.0\n')
    for version in ['v22.0.0', 'v24.0.0']:
        for name in ['node', 'npm', 'npx']:
            executable(nvm / 'versions/node' / version / 'bin' / name,
                       f"printf '%s\\n' '{name}-{version}'" if name != 'node'
                       else f"printf '%s\\n' '{version}'")


@unittest.skipUnless(os.environ.get('NVM_TEST_SCRIPT'), 'source tests/prepare-nvm-test.sh first')
class ShellStartup(unittest.TestCase):
    def setUp(self):
        self.f = fixture.MacSetup()
        self.f.setUp()
        self.addCleanup(self.f.doCleanups)
        self.home = self.f.home
        self.brew = self.f.base / 'brew prefix'
        (self.brew / 'bin').mkdir(parents=True)
        for name in ['mosh', 'tmux', 'git', 'gh']:
            shutil.move(self.f.bin / name, self.brew / 'bin' / name)
        executable(self.brew / 'bin/mosh-server', 'echo mosh-server-ready')
        executable(self.brew / 'sbin/test-admin', 'echo admin-ready')
        for name in ['codex', 'claude']:
            executable(self.home / '.local/bin' / name, f'echo {name}-ready')
        executable(self.home / '.bun/bin/bun', 'echo bun-ready')
        for name in ['node', 'npm', 'npx', 'codex', 'claude', 'bun']:
            p = self.f.bin / name
            if p.exists(): p.unlink()
        self.f.env['PATH'] = f'{self.brew / "bin"}:{self.f.env["PATH"]}'
        self.f.env['TEST_NVM_GLOB'] = '1'
        exports = '\n'.join([
            'export HOMEBREW_PREFIX=' + shlex.quote(str(self.brew)),
            'export HOMEBREW_CELLAR="$HOMEBREW_PREFIX/Cellar"',
            'export HOMEBREW_REPOSITORY="$HOMEBREW_PREFIX"',
            'export PATH="$HOMEBREW_PREFIX/bin:$HOMEBREW_PREFIX/sbin:$PATH"',
            'export MANPATH="$HOMEBREW_PREFIX/share/man:${MANPATH:-}"',
            'export INFOPATH="$HOMEBREW_PREFIX/share/info:${INFOPATH:-}"'])
        executable(self.brew / 'bin/brew',
                   'case "$1" in\n--version) echo brew-test ;;\n'
                   'shellenv) case "${2:-}" in sh|bash) ;; *) exit 91 ;; esac\n'
                   '[ "$2" != sh ] || [ -z "${BASH_ENV:-}" ] || { echo recursive-bash-env >&2; exit 92; }\n'
                   "printf '%s\\n' " + shlex.quote(exports) + ' ;;\n*) exit 1 ;;\nesac')
        (self.f.bin / 'brew').unlink()
        install_nvm_fixture(self.home)
        (self.home / '.bashrc').write_text(
            '# Custom config\ncase $- in *i*) ;; *) return ;; esac\nexport CUSTOM_SETTING=kept\n')
        self.f.run_setup('--select', 'shortcut', '--yes')

    def shell(self, executable_name, flags, command, **overrides):
        env = {'HOME': str(self.home), 'ZDOTDIR': str(self.home), 'PATH': '/usr/bin:/bin',
               'TERM': 'xterm-256color', 'LC_ALL': 'C', 'TEST_STATE': str(self.f.state)}
        env.update(overrides)
        binary = '/bin/bash' if executable_name == 'bash' else shutil.which(executable_name)
        return subprocess.run([binary, flags, command], env=env,
                              cwd=self.home, capture_output=True, text=True, timeout=30)

    def assert_runtime(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout.splitlines(), [
            'mosh-server-ready', 'codex-ready', 'claude-ready', 'bun-ready',
            'v22.0.0', 'npm-v22.0.0', 'npx-v22.0.0', 'admin-ready', 'ready'])

    def runtime_command(self):
        return ('mosh-server; codex; claude; bun; node --version; npm --version; npx --version; '
                'test-admin; test -n "$HOMEBREW_CELLAR" && test -n "$HOMEBREW_REPOSITORY" && '
                'test -n "$MANPATH" && test -n "$INFOPATH" && '
                'typeset -f t >/dev/null && typeset -f nvm >/dev/null && echo ready')

    def test_zsh_startup_modes(self):
        self.assertTrue(shutil.which('zsh'), 'Zsh is required for this test matrix')
        for flags in ['-c', '-ic', '-lc', '-lic']:
            with self.subTest(flags=flags):
                self.assert_runtime(self.shell('zsh', flags, self.runtime_command()))

    def test_bash_interactive_and_background(self):
        self.assert_runtime(self.shell('bash', '-ic', self.runtime_command()))
        # Non-login batch Bash has an explicit environment contract, not a
        # global BASH_ENV setting that would affect unrelated scripts.
        self.assert_runtime(self.shell('bash', '-c', self.runtime_command(),
                                      BASH_ENV=str(self.f.config / 'env.sh')))

    @unittest.skipIf(os.geteuid() == 0, 'Root harness: real SSH CI covers non-root login shells')
    def test_bash_login_modes(self):
        for flags in ['-lc', '-lic']:
            with self.subTest(flags=flags):
                self.assert_runtime(self.shell('bash', flags, self.runtime_command()))

    def test_bash_guard_and_rerun_preserve_custom_content(self):
        self.assert_runtime(self.shell('bash', '-c',
                                      '. "$HOME/.bashrc"; ' + self.runtime_command()))
        before = self.f.snapshot()
        self.f.run_setup('--select', 'shell,shortcut', '--yes')
        self.assertEqual(before, self.f.snapshot())
        profile = (self.home / '.bashrc').read_text()
        self.assertEqual(profile.count('# vps-setup:shell'), 1)
        self.assertLess(profile.index('# vps-setup:shell'), profile.index('return'))
        self.assertIn('export CUSTOM_SETTING=kept', profile)

    def test_startup_is_silent_and_does_not_start_tmux(self):
        for name in ['bash', 'zsh']:
            r = self.shell(name, '-c', ':', BASH_ENV=str(self.f.config / 'env.sh'))
            self.assertEqual((r.returncode, r.stdout, r.stderr), (0, '', ''))
        self.assertEqual(self.f.calls('tmux-calls'), '')

    def test_node_shebang_and_inherited_version(self):
        # A PATH fix must work for subprocesses too, not only wrapper functions.
        executable(self.home / 'script', '#!/usr/bin/env node')
        (self.home / 'script').write_text('#!/usr/bin/env node\n')
        r = self.shell('zsh', '-c', './script')
        self.assertEqual((r.returncode, r.stdout), (0, 'v22.0.0\n'))
        r = self.shell('zsh', '-c', 'nvm use --silent v24.0.0; zsh -c "node --version"')
        self.assertEqual((r.returncode, r.stdout), (0, 'v24.0.0\n'))
        # No version path is frozen at installation time.
        (self.home / '.nvm/alias/default').write_text('v24.0.0\n')
        r = self.shell('zsh', '-c', 'node --version')
        self.assertEqual((r.returncode, r.stdout), (0, 'v24.0.0\n'))

    def test_repeated_sourcing_preserves_version_and_path(self):
        r = self.shell('zsh', '-c',
                       'nvm use --silent v24.0.0; before=$PATH; '
                       '. "$HOME/.config/vps-setup/env.sh"; '
                       '. "$HOME/.config/vps-setup/env.sh"; '
                       'test "$PATH" = "$before" && node --version')
        self.assertEqual((r.returncode, r.stdout), (0, 'v24.0.0\n'))

    def test_bashrc_symlink_is_not_replaced_or_modified(self):
        rc = self.home / '.bashrc'
        rc.unlink()
        target = self.home / 'personal-bashrc'
        target.write_text('case $- in *i*) ;; *) return ;; esac\n')
        rc.symlink_to(target)
        before = self.f.snapshot()
        out = self.f.run_setup('--select', 'shell', '--yes')
        self.assertIn('Needs repair:', out)
        self.assertTrue(rc.is_symlink())
        self.assertEqual(before, self.f.snapshot())

    def test_batch_arguments_are_not_passed_to_nvm_initializer(self):
        nvm = self.home / '.nvm/nvm.sh'
        nvm.write_text('printf "%s\\n" "$#" > "$NVM_DIR/source-argcount"\n' + nvm.read_text())
        job = self.home / 'job.sh'
        job.write_text('printf "%s\\n" "$1"; node --version\n')
        env = {'HOME': str(self.home), 'PATH': '/usr/bin:/bin',
               'BASH_ENV': str(self.f.config / 'env.sh')}
        r = subprocess.run(['/bin/bash', str(job), '--install'], env=env,
                           capture_output=True, text=True, timeout=30)
        self.assertEqual((r.returncode, r.stdout), (0, '--install\nv22.0.0\n'))
        self.assertEqual((self.home / '.nvm/source-argcount').read_text(), '0\n')

    def test_login_path_reordering_keeps_selected_node(self):
        system_bin = self.f.base / 'system/bin'
        executable(system_bin / 'node', 'echo wrong-system-node')
        profile = self.home / '.zprofile'
        # Reproduce macOS path_helper ordering on every CI platform.
        profile.write_text('export PATH=' + shlex.quote(str(system_bin)) + ':"$PATH"\n'
                           + profile.read_text())
        r = self.shell('zsh', '-c',
                       "nvm use --silent v24.0.0; zsh -lc 'node --version; "
                       "printf \"%s\\n\" \"$PATH\"'")
        self.assertEqual(r.returncode, 0, r.stderr)
        lines = r.stdout.splitlines()
        self.assertEqual(lines[0], 'v24.0.0')
        self.assertEqual(lines[1].split(':').count(
            str(self.home / '.nvm/versions/node/v24.0.0/bin')), 1)

    @unittest.skipUnless(sys.platform == 'darwin' and shutil.which('brew'),
                         'Real Homebrew smoke check runs on macOS CI')
    def test_real_homebrew_environment(self):
        brew = Path(shutil.which('brew'))
        prefix = subprocess.check_output([str(brew), '--prefix'], text=True).strip()
        self.f.run_setup('--select', 'shell', '--yes',
                         PATH=str(brew.parent) + ':' + self.f.env['PATH'])
        for name in ['zsh', 'bash']:
            r = self.shell(name, '-c',
                           'printf "%s\\n" "$HOMEBREW_PREFIX" "$HOMEBREW_CELLAR" '
                           '"$HOMEBREW_REPOSITORY"; '
                           'case ":$PATH:" in *:"$HOMEBREW_PREFIX/sbin":*) echo sbin-ready ;; esac',
                           BASH_ENV=str(self.f.config / 'env.sh'))
            self.assertEqual(r.returncode, 0, r.stderr)
            lines = r.stdout.splitlines()
            self.assertEqual(lines[0], prefix)
            self.assertTrue(lines[1] and lines[2])
            self.assertEqual(lines[3], 'sbin-ready')


if __name__ == '__main__':
    unittest.main(verbosity=2)
