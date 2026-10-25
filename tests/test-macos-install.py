"""Local-only behavior tests. All installation, privileged and network tools are fake."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class MacSetup(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.home = self.base / "User's home"
        self.bin = self.base / 'bin'
        self.state = self.base / 'state'
        for p in [self.home, self.bin, self.state]:
            p.mkdir()
        self.config = self.home / '.config/vps-setup'
        self.workspace = self.home / 'dev $(touch BAD)'
        self.env = dict(os.environ, HOME=str(self.home), ZDOTDIR=str(self.home),
                        NVM_DIR=str(self.home / '.nvm'), XDG_CONFIG_HOME='',
                        PATH=f'{self.bin}:{os.environ["PATH"]}', TEST_STATE=str(self.state),
                        WORKSPACE_DIR=str(self.workspace), SUDO_USER='',
                        GH_RUNNER_REPO='', DEV_POSTGRES='0', MAC_TAILSCALE='1')
        self.env.pop('MAC_ALWAYS_ON', None)
        self.script('uname', 'echo "${TEST_OS:-Darwin}"')
        self.script('id', 'case "$1" in -u) echo "${TEST_UID:-501}" ;; -un) echo tester ;; esac')
        self.script('xcode-select', '[ "${NO_CLT:-0}" = 0 ]')
        self.script('brew', '''printf 'brew %s\\n' "$*" >> "$TEST_STATE/calls"
case "$1" in
 --version) [ "${BAD_BREW:-0}" = 0 ] && echo 'brew test' ;;
 shellenv) echo ':' ;;
 list) [ -f "$TEST_STATE/formula-$3" ] ;;
 install) [ "$3" != "${FAIL_INSTALL:-}" ] || exit 1
          touch "$TEST_STATE/tool-$3" "$TEST_STATE/formula-$3" ;;
 *) echo 'forbidden brew service or upgrade' >> "$TEST_STATE/forbidden"; exit 91 ;;
esac''')
        # Missing tool stubs are discovered as commands only after installed.
        # command -v is intercepted by a shell function supplied via BASH_ENV.
        self.bashenv = self.base / 'bashenv'
        self.bashenv.write_text('''command() {
 if [ "${1:-}" = -v ]; then
   if [ "${2:-}" = node ] && [ "${TEST_NVM_GLOB:-0}" = 1 ]; then
     local node_path
     node_path="$(builtin command -v node || true)"
     case "$node_path" in
       "$NVM_DIR"/versions/node/*/bin/node) printf '%s\\n' "$node_path"; return 0 ;;
       *) return 1 ;;
     esac
   fi
   case "${2:-}" in
     tailscale|tailscaled|mosh|tmux|git|gh|codex|claude|node|bun)
       [ -f "$TEST_STATE/tool-$2" ] || [ -f "$TEST_STATE/broken-$2" ] || return 1 ;;
   esac
 fi
 builtin command "$@"
}
''')
        self.env['BASH_ENV'] = str(self.bashenv)
        for tool in ['tailscale', 'mosh', 'tmux', 'git', 'gh', 'codex', 'claude', 'node', 'bun']:
            flag = '-V' if tool == 'tmux' else '--version'
            self.script(tool, f'''[ ! -f "$TEST_STATE/broken-{tool}" ] || exit 2
if [ "${{1:-}}" = {flag} ]; then echo '{tool} test-version'; exit 0; fi
''' + ('''printf 'tmux %s\\n' "$*" >> "$TEST_STATE/tmux-calls"
case "$1" in has-session) [ -f "$TEST_STATE/session" ] ;; new-session) touch "$TEST_STATE/session" ;; attach|switch-client) ;; *) exit 93 ;; esac''' if tool == 'tmux' else '''echo "forbidden tool operation $0 $*" >> "$TEST_STATE/forbidden"; exit 92'''))
        self.script('curl', '''printf 'curl %s\\n' "$*" >> "$TEST_STATE/calls"
[ "${FAIL_DOWNLOAD:-0}" = 0 ] || exit 22
case "$*" in
 *claude.ai/install.sh*) echo 'touch "$TEST_STATE/tool-claude"' ;;
 *chatgpt.com/codex/install.sh*) echo 'touch "$TEST_STATE/tool-codex"' ;;
 *bun.com/install*) echo 'touch "$TEST_STATE/tool-bun"' ;;
 *nvm-sh/nvm*) cat <<'EOF'
mkdir -p "$NVM_DIR"
if [ "${TEST_NVM_GLOB:-0}" = 1 ]; then
  cp "$TEST_STATE/nvm-fixture.sh" "$NVM_DIR/nvm.sh"
  exit 0
fi
cat > "$NVM_DIR/nvm.sh" <<'NVM'
nvm() {
  printf 'nvm %s\\n' "$*" >> "$TEST_STATE/calls"
  if [ "$1" = install ]; then touch "$TEST_STATE/tool-node"; fi
}
NVM
EOF
 ;;
 *) echo unexpected-download >> "$TEST_STATE/forbidden"; exit 95 ;;
esac''')
        for tool in ['sudo', 'launchctl', 'pmset', 'ssh', 'ping', 'nc', 'plutil', 'systemsetup', 'apt-get', 'systemctl', 'ufw']:
            self.script(tool, 'echo "forbidden $0 $*" >> "$TEST_STATE/forbidden"; exit 90')
        (self.home / '.zshrc').write_text('# user zsh customization\n')
        (self.home / '.profile').write_text('# user bash customization\n')
        self.install('git', 'gh', 'tmux', 'mosh', 'codex', 'claude')
        (self.home / 'Applications/Tailscale.app').mkdir(parents=True)

    def script(self, name, contents):
        p = self.bin / name
        p.write_text('#!/bin/bash\nset -eu\n' + contents + '\n')
        p.chmod(0o755)

    def install(self, *tools):
        for tool in tools:
            (self.state / ('tool-' + tool)).touch()

    def run_setup(self, *args, ok=True, **env):
        result = subprocess.run(['/bin/bash', str(ROOT / 'setup.sh'), *args],
                                env=dict(self.env, **env), capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode == 0, ok, result.stdout + result.stderr)
        self.assertFalse((self.state / 'forbidden').exists(), self.calls('forbidden'))
        return result.stdout + result.stderr

    def calls(self, name='calls'):
        p = self.state / name
        return p.read_text() if p.exists() else ''

    def snapshot(self):
        return {str(p.relative_to(self.home)): p.read_bytes() for p in self.home.rglob('*') if p.is_file()}

    def test_locked_and_read_only(self):
        before = self.snapshot()
        out = self.run_setup('--check')
        self.assertIn('LOCKED Tailscale', out)
        self.assertIn('LOCKED Codex', out)
        self.assertIn('test-version', out)
        self.assertNotIn('authentication=', out)
        self.assertEqual(before, self.snapshot())
        out = self.run_setup('--select', 'tailscale,codex', '--yes')
        self.assertIn('No eligible items', out)
        self.assertNotIn('brew install', self.calls())
        self.assertEqual(before, self.snapshot())
        self.assertIn('Manual steps', out)

    def test_missing_install_and_rerun(self):
        (self.state / 'tool-mosh').unlink()
        out = self.run_setup('--select', 'mosh,shortcut', '--dry-run')
        self.assertIn('Homebrew dependency', out)
        self.assertFalse(self.config.exists())
        out = self.run_setup('--select', 'mosh,shortcut', '--yes')
        self.assertIn('Installed — local version checked', out)
        self.assertIn('Configured — local content checked', out)
        self.assertTrue(self.workspace.is_dir())
        before = self.snapshot()
        (self.state / 'calls').write_text('')
        out = self.run_setup('--select', 'mosh,shortcut,shell', '--yes')
        self.assertEqual(before, self.snapshot())
        self.assertNotIn('brew install', self.calls())
        self.assertNotIn('curl ', self.calls())
        self.assertIn('Configuration current — kept', out)
        # Generated code preserves customizations and quotes unusual paths.
        self.assertIn('# user zsh customization', (self.home / '.zshrc').read_text())
        self.assertIn('# user bash customization', (self.home / '.profile').read_text())
        self.assertFalse((self.home / '.bash_profile').exists())
        result = subprocess.run(['/bin/bash', '-uc', '. "$HOME/.config/vps-setup/env.sh"; unset TMUX; t work'], env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(str(self.workspace), self.calls('tmux-calls'))
        self.assertFalse((ROOT / 'BAD').exists())
        if shutil.which('zsh'):
            result = subprocess.run(['zsh', '-fuc', '. "$HOME/.config/vps-setup/env.sh"; t work'], env=self.env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_existing_tailscale_variants_kept(self):
        self.run_setup('--select', 'tailscale', '--yes')
        (self.home / 'Applications/Tailscale.app').rmdir()
        self.install('tailscale')
        self.run_setup('--select', 'tailscale', '--yes')
        (self.state / 'tool-tailscale').unlink()
        (self.state / 'formula-tailscale').touch()
        self.run_setup('--select', 'tailscale', '--yes')
        (self.state / 'formula-tailscale').unlink()
        self.script('tailscaled', 'echo daemon-must-not-run >> "$TEST_STATE/forbidden"; exit 99')
        self.install('tailscaled')
        self.assertIn('tailscaled present', self.run_setup('--select', 'tailscale', '--yes'))
        self.assertNotIn('brew install', self.calls())
        self.assertNotIn('services', self.calls())

    def test_homebrew_download_execute_and_cleanup(self):
        # Isolate the dependency helper so host Homebrew prefixes cannot leak in.
        download_dir = self.base / 'downloads'
        download_dir.mkdir()
        self.script('curl', '''[ "$2" = https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh ]
[ "$3" = -o ]
[ "${FAIL_DOWNLOAD:-0}" = 0 ] || exit 22
cat > "$4" <<'INSTALL'
[ "${FAIL_SCRIPT:-0}" = 0 ] || exit 23
touch "$TEST_STATE/homebrew-installer-ran"
INSTALL''')
        script = '''. "$1/macos/lib.sh"
BREW_BIN=''; BREW_BROKEN=0
TEST_BREW="$2"
mac_find_brew() { BREW_BIN="$TEST_BREW"; BREW_BROKEN=0; }
mac_ensure_brew
'''
        for overrides, success in [({'FAIL_DOWNLOAD': '1'}, False),
                                   ({'FAIL_SCRIPT': '1'}, False), ({}, True)]:
            result = subprocess.run(['/bin/bash', '-eu', '-c', script, '_', str(ROOT), str(self.bin / 'brew')],
                                    env=dict(self.env, TMPDIR=str(download_dir), **overrides),
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode == 0, success, result.stderr)
            self.assertEqual(list(download_dir.iterdir()), [])
            self.assertEqual((self.state / 'homebrew-installer-ran').exists(), success)

    def test_new_tailscale_install_only(self):
        (self.home / 'Applications/Tailscale.app').rmdir()
        out = self.run_setup('--select', 'tailscale', '--yes')
        self.assertIn('brew install --formula tailscale', self.calls())
        self.assertIn('Installed — local version checked', out)
        self.assertNotIn('brew services', self.calls())

    def test_broken_tool_is_locked_not_reinstalled(self):
        (self.state / 'broken-codex').touch()
        out = self.run_setup('--select', 'codex', '--yes')
        self.assertIn('Manual repair needed — not changed', out)
        self.assertNotIn('curl ', self.calls())
        self.assertFalse(self.config.exists())

    def test_saved_choices_retire_manual_and_lock_installed(self):
        self.config.mkdir(parents=True)
        selection = self.config / 'selection.txt'
        selection.write_text('ssh,screen,power,tailscale,codex\n')
        before = self.snapshot()
        out = self.run_setup('--dry-run')
        self.assertIn('Retired saved choice', out)
        self.assertNotIn('install missing tool', out)
        self.assertEqual(before, self.snapshot())
        selection.write_text('ssh,unknown-item')
        self.run_setup('--dry-run', ok=False)
        for name in ['ssh', 'screen', 'power']:
            self.assertIn('is manual', self.run_setup('--select', name, '--yes', ok=False))

    def test_none_and_cancel_no_writes(self):
        before = self.snapshot()
        self.run_setup('--select', 'none', '--yes', MAC_ALWAYS_ON='1')
        self.assertEqual(before, self.snapshot())
        result = subprocess.run(['python3', str(ROOT / 'tests/test-macos-menu.py'), str(ROOT / 'setup.sh')], env=self.env, capture_output=True, text=True, timeout=40)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(before, self.snapshot())

    def test_failures_retry_and_independent_agents(self):
        (self.state / 'tool-codex').unlink()
        out = self.run_setup('--select', 'codex', '--yes', ok=False, FAIL_DOWNLOAD='1')
        self.assertIn('Failed — installation incomplete', out)
        self.assertFalse((self.config / 'selection.txt').exists())
        self.run_setup('--select', 'codex', '--yes')
        self.assertNotIn('claude.ai', self.calls())
        self.assertNotIn('nvm-sh', self.calls())
        self.assertNotIn('bun.com', self.calls())
        (self.state / 'tool-mosh').unlink()
        out = self.run_setup('--select', 'mosh', '--yes', ok=False, FAIL_INSTALL='mosh')
        self.assertIn('Failed — installation incomplete', out)
        self.run_setup('--select', 'mosh', '--yes')

    def test_optional_runtimes_independent(self):
        self.run_setup('--select', 'bun', '--yes')
        self.assertIn('bun.com/install', self.calls())
        self.assertNotIn('nvm-sh', self.calls())
        (self.state / 'calls').write_text('')
        self.run_setup('--select', 'node', '--yes')
        self.assertIn('nvm-sh/nvm/v0.40.8/install.sh', self.calls())
        self.assertNotIn('bun.com', self.calls())
        self.assertTrue((self.state / 'tool-node').exists())

    def nvm_glob_fixture(self, existing=False):
        # Model nvm's glob-based version discovery, with Node absent from PATH.
        fixture = self.state / 'nvm-fixture.sh'
        fixture.write_text('''nvm() {
  case "$1" in
    install)
      mkdir -p "$NVM_DIR/versions/node/v24.0.0/bin"
      cp "$TEST_STATE/node-template" "$NVM_DIR/versions/node/v24.0.0/bin/node"
      nvm use default ;;
    use)
      local node_bin
      for node_bin in "$NVM_DIR"/versions/node/v*/bin; do
        [ -x "$node_bin/node" ] || continue
        export PATH="$node_bin:$PATH"
        return 0
      done
      return 3 ;;
    alias) return 0 ;;
  esac
}
''')
        shutil.copy2(self.bin / 'node', self.state / 'node-template')
        (self.bin / 'node').unlink()
        if existing:
            nvm_dir = Path(self.env['NVM_DIR'])
            node_bin = nvm_dir / 'versions/node/v24.0.0/bin'
            node_bin.mkdir(parents=True)
            shutil.copy2(self.state / 'node-template', node_bin / 'node')
            shutil.copy2(fixture, nvm_dir / 'nvm.sh')

    def test_nvm_existing_node_outside_path_is_locked(self):
        self.nvm_glob_fixture(existing=True)
        before = self.snapshot()
        out = self.run_setup('--select', 'node', '--yes', TEST_NVM_GLOB='1')
        self.assertIn('LOCKED Node.js / nvm', out)
        self.assertNotIn('curl ', self.calls())
        self.assertEqual(before, self.snapshot())

    def test_nvm_new_node_activated_for_post_install_check(self):
        self.nvm_glob_fixture()
        out = self.run_setup('--select', 'node', '--yes', TEST_NVM_GLOB='1')
        self.assertIn('Installed — local version checked', out)
        before = self.snapshot()
        (self.state / 'calls').write_text('')
        self.run_setup('--select', 'node', '--yes', TEST_NVM_GLOB='1')
        self.assertNotIn('curl ', self.calls())
        self.assertEqual(before, self.snapshot())

    def test_selection_patterns_stay_literal(self):
        # A glob matching a valid component must be rejected, not selected.
        (self.base / 'node').touch()
        self.config.mkdir(parents=True)
        saved = self.config / 'selection.txt'
        for value in ['n*', 'node\\n[nb]*', '$(touch OWNED)']:
            saved.write_text(value)
            for args in [('--dry-run',), ('--select', value, '--dry-run')]:
                result = subprocess.run(['/bin/bash', str(ROOT / 'setup.sh'), *args],
                                        cwd=self.base, env=self.env, capture_output=True,
                                        text=True, timeout=30)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn('Unknown component', result.stderr)
        self.assertFalse((self.base / 'OWNED').exists())

    def test_config_update_and_symlink(self):
        self.run_setup('--select', 'shortcut', '--yes')
        before = (self.home / '.zshrc.vps-setup.bak').read_bytes()
        newdir = str(self.home / 'new workspace')
        out = self.run_setup('--select', 'shortcut', '--yes', WORKSPACE_DIR=newdir)
        self.assertIn('Configured', out)
        self.assertIn('new\\ workspace', (self.config / 'tmux.sh').read_text())
        self.assertEqual(before, (self.home / '.zshrc.vps-setup.bak').read_bytes())
        target = self.home / 'custom-profile'
        target.write_text('# personal\n')
        (self.home / '.zshrc').unlink()
        (self.home / '.zshrc').symlink_to(target)
        out = self.run_setup('--select', 'shell', '--yes')
        self.assertIn('Manual repair needed', out)
        self.assertEqual(target.read_text(), '# personal\n')

    def test_guards(self):
        self.run_setup('--yes', ok=False)
        self.run_setup('--check', ok=False, TEST_UID='0')
        self.run_setup('--check', ok=False, TEST_OS='FreeBSD')
        self.run_setup('--check', ok=False, GH_RUNNER_REPO='owner/repo')
        (self.state / 'tool-mosh').unlink()
        self.run_setup('--select', 'mosh', '--yes', ok=False, NO_CLT='1')
        self.assertFalse(self.config.exists())
        self.run_setup('--select', 'mosh', '--yes', ok=False, BAD_BREW='1')
        self.assertFalse(self.config.exists())


if __name__ == '__main__':
    unittest.main(verbosity=2)
