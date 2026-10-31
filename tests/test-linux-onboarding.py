"""Linux adapter tests: fake privileged commands, real shared engine and Gum."""
import importlib.util
import os
import shutil
import subprocess
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('gum_fixture', ROOT / 'tests/test-macos-gum.py')
gum = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gum)


class LinuxOnboarding(unittest.TestCase):
    def setUp(self):
        self.f = gum.fixture.MacSetup()
        self.f.setUp()
        self.addCleanup(self.f.doCleanups)
        self.f.env.update(TEST_OS='Linux', TERM='xterm-256color')
        self.env = self.f.env
        self.f.install('tailscale')
        self.f.script('getent', 'printf "tester:x:501:501::%s:/bin/bash\\n" "$HOME"')
        self.f.script('dpkg-query', '''case "$*" in
 *postgresql*) [ "${TEST_POSTGRES:-0}" = 1 ] && printf 'install ok installed' ;;
 *) exit 1 ;;
esac''')
        self.f.script('sudo', '''printf 'sudo %s\\n' "$*" >> "$TEST_STATE/calls"
[ "$1" != -v ] || exit 0
[ "$1" = env ] || { echo forbidden-sudo >> "$TEST_STATE/forbidden"; exit 90; }
exec "$@"''')
        self.f.script('apt-get', '''printf 'apt-get %s\\n' "$*" >> "$TEST_STATE/calls"
[ "${FAIL_APT:-0}" = 0 ] || exit 23
if [ "$1" = install ]; then
 shift
 for pkg in "$@"; do
   case "$pkg" in -y) ;; git|tmux|mosh|unzip|curl) touch "$TEST_STATE/tool-$pkg" ;;
     *) echo "unexpected package $pkg" >> "$TEST_STATE/forbidden"; exit 90 ;;
   esac
 done
fi''')
        # Model curl missing from PATH until apt installs it, in every child Bash.
        bashenv = self.f.bashenv.read_text().replace(
            ' if [ "${1:-}" = -v ]; then',
            ' if [ "${1:-}" = -v ]; then\n'
            '   if [ "${2:-}" = curl ] && [ "${TEST_NO_CURL:-0}" = 1 ] '
            '&& [ ! -f "$TEST_STATE/tool-curl" ]; then return 1; fi')
        self.f.bashenv.write_text(bashenv)
        curl = self.f.bin / 'curl'
        curl.write_text(curl.read_text().replace(
            'set -eu\n', 'set -eu\n'
            '[ "${TEST_NO_CURL:-0}" != 1 ] || [ -f "$TEST_STATE/tool-curl" ] '
            '|| { echo "curl: command not found" >&2; exit 127; }\n', 1))
        # Any macOS adapter call would fail the test.
        for tool in ['brew', 'xcode-select']:
            self.f.script(tool, 'echo "mac-only $0" >> "$TEST_STATE/forbidden"; exit 90')

    def test_preview_plan_and_inventory_are_read_only(self):
        before = self.f.snapshot()
        out = self.f.run_setup('--select', 'preview-service', '--dry-run')
        self.assertIn('Host static HTML previews on this machine through private Tailscale links.', out)
        self.assertIn('private Tailscale HTTPS :8443', out)
        self.assertIn('Preview service', self.f.run_setup('--check'))
        self.assertEqual(before, self.f.snapshot())
        self.assertEqual(self.f.calls(), '')

    def test_inventory_plan_and_none_are_read_only(self):
        before = self.f.snapshot()
        out = self.f.run_setup('--check')
        self.assertIn('Package manager: apt', out)
        self.assertIn('LOCKED Tailscale', out)
        self.assertIn('Linux security baseline', out)
        out = self.f.run_setup('--dry-run')
        self.assertIn('Key-only SSH when an authorized key exists', out)
        self.assertIn('prune Docker build cache and dangling images', out)
        self.assertNotIn('  - Install Node.js / nvm', out)
        self.f.run_setup('--select', 'none', '--yes')
        self.assertEqual(before, self.f.snapshot())
        self.assertEqual(self.f.calls(), '')

    def test_plan_keeps_consequential_system_settings(self):
        before = self.f.snapshot()
        out = self.f.run_setup('--select', 'security,disk-guard,runner,postgres',
                               '--dry-run', SSH_PORT='2222', DISK_GUARD_CLEAN_PCT='95',
                               GH_RUNNER_REPO='owner/repo')
        for detail in ['Key-only SSH when an authorized key exists', '2222/tcp',
                       'Mosh UDP', 'tailscale0', 'fail2ban', 'automatic security updates',
                       '200 MB', 'prune Docker build cache and dangling images at 95%',
                       'owner/repo', 'system service', 'ghrunner',
                       'local socket, peer auth', 'Database superuser:']:
            self.assertIn(detail, out)
        self.assertEqual(before, self.f.snapshot())
        self.assertEqual(self.f.calls(), '')

    def test_only_selected_package_and_config_then_noop_rerun(self):
        (self.f.state / 'tool-mosh').unlink()
        out = self.f.run_setup('--select', 'mosh,shortcut', '--yes')
        self.assertIn('Installed', out)
        self.assertIn('apt-get install -y mosh', self.f.calls())
        self.assertNotIn('ufw', self.f.calls())
        before = self.f.snapshot()
        (self.f.state / 'calls').write_text('')
        out = self.f.run_setup('--select', 'mosh,shortcut,shell', '--yes')
        self.assertIn('No changes selected.', out)
        self.assertEqual(before, self.f.snapshot())
        self.assertEqual(self.f.calls(), '')

    def test_native_install_is_independent_and_unprivileged(self):
        (self.f.state / 'tool-codex').unlink()
        self.f.run_setup('--select', 'codex', '--yes')
        self.assertIn('chatgpt.com/codex/install.sh', self.f.calls())
        self.assertNotIn('sudo', self.f.calls())
        self.assertNotIn('claude.ai', self.f.calls())
        self.assertNotIn('nvm-sh', self.f.calls())

    def test_missing_curl_installed_before_selected_native_tool(self):
        """A wget/git/local bootstrap must still support native installation."""
        self.env['TEST_NO_CURL'] = '1'
        (self.f.state / 'tool-codex').unlink()
        before = self.f.snapshot()
        out = self.f.run_setup('--select', 'codex', '--dry-run')
        self.assertIn('  - Install curl (dependency, apt)', out)
        self.assertEqual(before, self.f.snapshot())
        self.assertEqual(self.f.calls(), '')
        out = self.f.run_setup('--select', 'codex', '--yes')
        self.assertIn('Installed', out)
        calls = self.f.calls()
        self.assertLess(calls.index('apt-get install -y curl'),
                        calls.index('curl -fsSL https://chatgpt.com/codex/install.sh'))
        self.assertNotIn('claude.ai', calls)
        before = self.f.snapshot()
        (self.f.state / 'calls').write_text('')
        self.f.run_setup('--select', 'codex,shell', '--yes')
        self.assertEqual(before, self.f.snapshot())
        self.assertEqual(self.f.calls(), '')

    def test_curl_dependency_failure_stops_before_native_download(self):
        """A failed prerequisite must not run a dependent installer or save success."""
        self.env['TEST_NO_CURL'] = '1'
        (self.f.state / 'tool-codex').unlink()
        self.f.run_setup('--select', 'codex', '--yes', ok=False, FAIL_APT='1')
        self.assertNotIn('curl -fsSL', self.f.calls())
        self.assertFalse((self.f.state / 'tool-codex').exists())
        self.assertFalse((self.f.config / 'selection.txt').exists())

    def test_every_network_installer_plans_missing_curl(self):
        """All curl-consuming modules, including the optional runner, declare it."""
        self.env['TEST_NO_CURL'] = '1'
        for tool in ['gh', 'tailscale', 'node', 'bun', 'codex', 'claude', 'runner']:
            with self.subTest(tool=tool):
                marker = self.f.state / ('tool-' + tool)
                if marker.exists():
                    marker.unlink()
                out = self.f.run_setup('--select', tool, '--dry-run')
                self.assertIn('  - Install curl (dependency, apt)', out)
        self.assertFalse((self.f.state / 'tool-curl').exists())
        self.assertEqual(self.f.calls(), '')

    def test_missing_curl_not_installed_for_unrelated_or_locked_choices(self):
        """Only eligible network work can add curl to the installation plan."""
        self.env['TEST_NO_CURL'] = '1'
        for selection in ['none', 'codex', 'shell']:
            out = self.f.run_setup('--select', selection, '--yes')
            self.assertNotIn('  - Install curl (dependency, apt)', out)
        (self.f.state / 'tool-mosh').unlink()
        self.f.run_setup('--select', 'mosh', '--yes')
        self.assertIn('apt-get install -y mosh', self.f.calls())
        self.assertNotIn('apt-get install -y curl', self.f.calls())
        self.assertFalse((self.f.state / 'tool-curl').exists())

    def test_broken_and_existing_packages_locked(self):
        (self.f.state / 'broken-codex').touch()
        out = self.f.run_setup('--select', 'codex,postgres', '--yes', TEST_POSTGRES='1')
        self.assertIn('Needs repair:', out)
        self.assertIn('Local PostgreSQL', out)
        self.assertEqual(self.f.calls(), '')

    def test_failure_does_not_save_success_and_retry_works(self):
        (self.f.state / 'tool-mosh').unlink()
        self.f.run_setup('--select', 'mosh', '--yes', ok=False, FAIL_APT='1')
        self.assertFalse((self.f.config / 'selection.txt').exists())
        self.f.run_setup('--select', 'mosh', '--yes')
        self.assertTrue((self.f.state / 'tool-mosh').exists())

    def test_runner_and_sudo_guards_before_writes(self):
        before = self.f.snapshot()
        self.f.run_setup('--select', 'runner', '--yes', ok=False)
        self.f.run_setup('--check', ok=False, TEST_UID='0', SUDO_USER='tester')
        self.assertEqual(before, self.f.snapshot())
        self.assertEqual(self.f.calls(), '')

    def test_selected_system_modules_run_before_external_installers(self):
        # Keep the real orchestrator/adapter; isolate system module bodies.
        repo = self.f.base / 'repo'
        shutil.copytree(ROOT, repo, ignore=shutil.ignore_patterns('.git', '__pycache__'))
        for name in ['15-ssh-hardening', '20-firewall', '25-fail2ban',
                     '30-auto-updates', '35-disk-guard']:
            (repo / 'modules' / (name + '.sh')).write_text(
                'printf "%s\\n" "' + name + '" >> "$TEST_STATE/order"\n')
        (repo / 'modules/70-agents.sh').write_text(
            'echo agents >> "$TEST_STATE/order"\ntouch "$TEST_STATE/tool-codex"\n')
        (self.f.state / 'tool-codex').unlink()
        result = subprocess.run(['/bin/bash', str(repo / 'setup.sh'), '--select',
                                 'security,disk-guard,codex', '--yes'],
                                env=self.env, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.f.calls('order').splitlines(), [
            '15-ssh-hardening', '20-firewall', '25-fail2ban',
            '30-auto-updates', '35-disk-guard', 'agents'])
        self.assertFalse((self.f.state / 'forbidden').exists())

    def test_gum_keyboard_apply_and_locked_rerun(self):
        if not gum.REAL_GUM:
            self.skipTest('GUM_TEST_BIN required in CI')
        (self.f.bin / 'gum').symlink_to(gum.REAL_GUM)
        (self.f.state / 'tool-mosh').unlink()
        self.f.config.mkdir(parents=True)
        (self.f.config / 'selection.txt').write_text('mosh')
        t = gum.Terminal(self.env, piped_input=True)
        self.addCleanup(t.close)
        t.menu('Choose tools to install')
        self.assertIn(b'[x] Mosh', t.output)
        self.assertNotIn(b'[ ] Tailscale', t.output)
        t.send(b'\x1b[B')
        t.expect('> [ ] Node.js / nvm')
        t.send(b' ')
        t.expect('> [x] Node.js / nvm')
        t.send(b' ')
        t.expect('> [ ] Node.js / nvm')
        t.send(b'\r')
        t.menu('Choose configuration updates')
        self.assertIn(b'Linux security baseline', t.output)
        t.send(b'\r')
        t.expect('n Cancel')
        t.send(b'y')
        t.expect('n Skip')
        t.send(b'\r')
        out = t.finish()
        self.assertIn('Installed', out)
        self.assertIn('Tools selected: Mosh', out)
        self.assertIn('Configuration selected: Shell integration (required)', out)
        self.assertIn('apt-get install -y mosh', self.f.calls())
        before = self.f.snapshot()
        t = gum.Terminal(self.env)
        self.addCleanup(t.close)
        t.menu('Choose tools to install')
        self.assertNotIn(b'[x] Mosh', t.output)
        self.assertNotIn(b'[ ] Mosh', t.output)
        t.send(b'\x1b')
        t.finish()
        self.assertEqual(before, self.f.snapshot())

    def test_gum_failure_has_no_package_side_effects(self):
        self.f.script('gum', 'exit 1')
        self.f.script('uname', 'case "$1" in -s) echo Linux ;; -m) echo x86_64 ;; esac')
        self.f.script('curl', 'exit 22')
        before = self.f.snapshot()
        t = gum.Terminal(self.env)
        self.addCleanup(t.close)
        self.assertIn('Cannot prepare Gum', t.finish(expected=1))
        self.assertEqual(before, self.f.snapshot())
        self.assertEqual(self.f.calls(), '')


if __name__ == '__main__':
    unittest.main(verbosity=2)
