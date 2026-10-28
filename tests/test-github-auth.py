"""Optional login uses a real terminal/UI with isolated credential commands."""
import importlib.util
from pathlib import Path
import subprocess
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('gum_fixture', ROOT / 'tests/test-macos-gum.py')
gum = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gum)


class GitHubAuth(unittest.TestCase):
    def setUp(self):
        self.f = gum.fixture.MacSetup()
        self.f.setUp()
        self.addCleanup(self.f.doCleanups)
        self.env = self.f.env
        self.env.update(TERM='xterm-256color', NO_COLOR='1', GH_TOKEN='', GITHUB_TOKEN='')
        self.f.script('security', '''
printf 'security %s\\n' "$*" >> "$TEST_STATE/auth-calls"
[ -t 0 ] && [ -t 1 ] && [ -t 2 ] || exit 80
[ "$#" = 1 ] && [ "$1" = unlock-keychain ] || exit 81
stty -echo
trap 'stty echo' EXIT
printf 'Fake Keychain password: '
IFS= read -r password
stty echo
printf '\\n'
[ "$password" = test-password ] || exit 82
[ "${FAIL_UNLOCK:-0}" = 0 ] || exit 83
if [ "${UNLOCK_RESTORES_AUTH:-0}" = 1 ]; then touch "$TEST_STATE/authenticated"; fi
''')
        self.f.script('gh', '''
[ "${1:-}" != --version ] || { echo 'gh test-version'; exit 0; }
printf 'gh %s\\n' "$*" >> "$TEST_STATE/auth-calls"
case "$*" in
 'auth status --active --hostname github.com')
   if [ "${WAIT_FOR_STATUS:-0}" = 1 ] && [ -t 0 ]; then
     touch "$TEST_STATE/status-pending"
     IFS= read -r answer
   fi
   [ -f "$TEST_STATE/authenticated" ] || [ "${ENV_AUTH_VALID:-0}" = 1 ] || exit 1
   [ "${FAIL_FINAL_STATUS:-0}" = 0 ] || [ ! -f "$TEST_STATE/helper-configured" ] || exit 1
   printf 'Logged in as tester (%s)\\n' "${TEST_TOKEN_SOURCE:-keyring}"
   ;;
 'auth login --hostname github.com --git-protocol https --web')
   [ -t 0 ] && [ -t 1 ] && [ -t 2 ] || exit 80
   printf 'Fake device code DEVICE-CODE; press Enter: '
   IFS= read -r answer
   [ "${FAIL_LOGIN:-0}" = 0 ] || exit 84
   touch "$TEST_STATE/authenticated"
   if [ "${TEST_TOKEN_SOURCE:-}" = hosts.yml ]; then printf 'Authentication credentials saved in plain text\\n'; fi
   ;;
 'auth setup-git --hostname github.com')
   [ "${FAIL_HELPER:-0}" = 0 ] || exit 85
   touch "$TEST_STATE/helper-configured"
   ;;
 *) echo "unexpected gh $*" >> "$TEST_STATE/forbidden"; exit 90 ;;
esac
''')

    def terminal(self, *args, **kwargs):
        if not gum.REAL_GUM:
            self.skipTest('Set GUM_TEST_BIN to the verified pinned Gum binary (required in CI)')
        if not (self.f.bin / 'gum').exists():
            (self.f.bin / 'gum').symlink_to(gum.REAL_GUM)
        terminal = gum.Terminal(self.env, *args, **kwargs)
        self.addCleanup(terminal.close)
        return terminal

    def offer(self, selection='shell', **kwargs):
        t = self.terminal('--select', selection, **kwargs)
        t.expect('n Cancel')
        t.send(b'y')
        t.expect('n Skip')
        return t

    def unlock(self, t):
        t.expect('Fake Keychain password: ')
        t.send(b'test-password\n')

    def login(self, t):
        t.expect('Fake device code DEVICE-CODE; press Enter: ')
        t.send(b'\n')

    def calls(self):
        return self.f.calls('auth-calls')

    def documented_login(self):
        instructions = (ROOT / 'README.md').read_text().split('If you skipped the step,', 1)[1]
        snippet = instructions.split('```bash\n', 1)[1].split('```', 1)[0]
        script = self.f.base / 'documented-login.sh'
        script.write_text(snippet)
        terminal = gum.Terminal(self.env, script=script)
        self.addCleanup(terminal.close)
        return terminal

    def assert_install_preserved(self):
        self.assertTrue((self.f.config / 'selection.txt').is_file())
        self.assertFalse((self.f.state / 'forbidden').exists(), self.f.calls('forbidden'))

    def test_offer_only_when_authentication_is_unavailable(self):
        # Exercise the gate without requiring Gum or a real GitHub account.
        script = '''
set -eu
source "$1/lib/github-auth.sh"
on_tool() { [ "${TEST_GH_AVAILABLE:-1}" = 1 ]; }
ui_gum() { printf 'SIGN-IN-PROMPT\\n' >&4; return 1; }
exec 4>&1
on_offer_github_login
'''
        for scenario in ['stored', 'GH_TOKEN', 'GITHUB_TOKEN', 'missing', 'invalid', 'no-gh']:
            with self.subTest(scenario=scenario):
                authenticated = self.f.state / 'authenticated'
                authenticated.unlink(missing_ok=True)
                (self.f.state / 'auth-calls').unlink(missing_ok=True)
                env = dict(self.env)
                valid = scenario in ['stored', 'GH_TOKEN', 'GITHUB_TOKEN']
                if scenario == 'stored':
                    authenticated.touch()
                elif scenario in ['GH_TOKEN', 'GITHUB_TOKEN']:
                    env.update({scenario: 'test-env-token', 'ENV_AUTH_VALID': '1'})
                elif scenario == 'invalid':
                    env['GH_TOKEN'] = 'invalid-test-token'
                elif scenario == 'no-gh':
                    env['TEST_GH_AVAILABLE'] = '0'
                result = subprocess.run(['/bin/bash', '-c', script, '_', str(ROOT)],
                                        env=env, capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
                output = result.stdout + result.stderr
                offered = not valid and scenario != 'no-gh'
                self.assertEqual('Optional GitHub HTTPS authentication' in output, offered)
                self.assertEqual('SIGN-IN-PROMPT' in output, offered)
                self.assertNotIn('test-env-token', output)
                self.assertNotIn('Logged in as tester', output)
                self.assertEqual(self.calls(), '' if scenario == 'no-gh' else
                                 'gh auth status --active --hostname github.com\n')

    def test_skip_is_default_and_only_checks_status(self):
        t = self.offer()
        t.send(b'\r')
        self.assertIn('GitHub authentication skipped.', t.finish())
        self.assertEqual(self.calls(), 'gh auth status --active --hostname github.com\n')
        self.assert_install_preserved()

    def test_escape_and_ctrl_c_skip_optional_prompt(self):
        for key in [b'\x1b', b'\x03']:
            with self.subTest(key=key):
                t = self.offer()
                t.send(key)
                self.assertIn('GitHub authentication skipped.', t.finish())
                self.assertEqual(set(self.calls().splitlines()),
                                 {'gh auth status --active --hostname github.com'})
                self.assert_install_preserved()
                (self.f.config / 'env.sh').unlink()

    def test_new_mac_install_uses_default_keychain_and_terminal_stdin(self):
        (self.f.state / 'tool-gh').unlink()
        t = self.offer('gh', piped_input=True)
        t.send(b'y')
        self.unlock(t)
        self.login(t)
        out = t.finish()
        self.assertIn('GitHub authentication and Git credential helper verified.', out)
        self.assertIn('(keyring)', out)
        self.assertIn('Storage check:', out)
        self.assertNotIn('test-password', out)
        calls = self.calls()
        self.assertLess(calls.index('security unlock-keychain'), calls.index('gh auth login'))
        self.assertIn('security unlock-keychain\n', calls)
        self.assertLess(calls.index('gh auth login'), calls.index('gh auth setup-git'))
        self.assertNotIn('test-password', calls)
        self.assert_install_preserved()

    def test_unlock_restores_existing_auth_without_logging_in_again(self):
        self.env['UNLOCK_RESTORES_AUTH'] = '1'
        t = self.offer()
        t.send(b'y')
        self.unlock(t)
        self.assertIn('Git credential helper verified.', t.finish())
        self.assertNotIn('gh auth login', self.calls())
        self.assertIn('gh auth setup-git', self.calls())

    def test_existing_auth_skips_optional_step(self):
        (self.f.state / 'authenticated').touch()
        t = self.terminal('--select', 'shell')
        t.expect('n Cancel')
        t.send(b'y')
        out = t.finish()
        self.assertNotIn('Optional GitHub HTTPS authentication', out)
        self.assertNotIn('Set up GitHub authentication now?', out)
        self.assertEqual(self.calls(), 'gh auth status --active --hostname github.com\n')
        self.assert_install_preserved()

    def test_environment_auth_is_preserved(self):
        self.env.update(GH_TOKEN='test-env-token', ENV_AUTH_VALID='1')
        t = self.terminal('--select', 'shell')
        t.expect('n Cancel')
        t.send(b'y')
        out = t.finish()
        self.assertNotIn('Optional GitHub HTTPS authentication', out)
        self.assertNotIn('Set up GitHub authentication now?', out)
        self.assertNotIn('test-env-token', out + self.calls())
        self.assertNotIn('security ', self.calls())
        self.assertNotIn('gh auth login', self.calls())
        self.assertEqual(self.calls(), 'gh auth status --active --hostname github.com\n')

    def test_invalid_environment_auth_does_not_start_login(self):
        self.env['GITHUB_TOKEN'] = 'invalid-test-token'
        t = self.offer()
        t.send(b'y')
        self.assertIn('did not finish', t.finish())
        self.assertNotIn('security ', self.calls())
        self.assertNotIn('gh auth login', self.calls())
        self.assertNotIn('gh auth setup-git', self.calls())
        self.assert_install_preserved()

    def test_unlock_failure_stops_before_login(self):
        self.env['FAIL_UNLOCK'] = '1'
        t = self.offer()
        t.send(b'y')
        self.unlock(t)
        self.assertIn('did not finish', t.finish())
        self.assertNotIn('gh auth login', self.calls())
        self.assertNotIn('gh auth setup-git', self.calls())
        self.assert_install_preserved()

    def test_login_failure_does_not_configure_helper_or_fail_install(self):
        self.env['FAIL_LOGIN'] = '1'
        t = self.offer()
        t.send(b'y')
        self.unlock(t)
        self.login(t)
        self.assertIn('did not finish', t.finish())
        self.assertNotIn('gh auth setup-git', self.calls())
        self.assert_install_preserved()

    def test_ctrl_c_during_unlock_or_login_keeps_installation_result(self):
        for stage in ['unlock', 'login']:
            with self.subTest(stage=stage):
                t = self.offer()
                t.send(b'y')
                if stage == 'login':
                    self.unlock(t)
                    t.expect('Fake device code DEVICE-CODE; press Enter: ')
                else:
                    t.expect('Fake Keychain password: ')
                t.send(b'\x03')
                out = t.finish()
                self.assertIn('did not finish', out)
                self.assertNotIn('Git credential helper verified.', out)
                self.assertNotIn('gh auth setup-git', self.calls())
                self.assert_install_preserved()
                (self.f.config / 'env.sh').unlink()

    def test_ctrl_c_during_initial_status_does_not_start_unlock_or_login(self):
        self.env['WAIT_FOR_STATUS'] = '1'
        t = self.offer()
        t.send(b'y')
        deadline = time.monotonic() + 10
        while not (self.f.state / 'status-pending').exists():
            self.assertLess(time.monotonic(), deadline)
            t.read()
        t.send(b'\x03')
        self.assertIn('did not finish', t.finish())
        self.assertNotIn('security ', self.calls())
        self.assertNotIn('gh auth login', self.calls())
        self.assertNotIn('gh auth setup-git', self.calls())
        self.assert_install_preserved()

    def test_helper_or_final_verification_failure_is_reported(self):
        for failure in ['FAIL_HELPER', 'FAIL_FINAL_STATUS']:
            with self.subTest(failure=failure):
                (self.f.state / 'authenticated').unlink(missing_ok=True)
                self.env[failure] = '1'
                t = self.offer()
                t.send(b'y')
                self.unlock(t)
                self.login(t)
                out = t.finish()
                self.assertIn('did not finish', out)
                self.assertNotIn('Git credential helper verified.', out)
                self.assert_install_preserved()
                self.env[failure] = '0'
                (self.f.config / 'env.sh').unlink()

    def test_plaintext_fallback_remains_visible(self):
        self.env['TEST_TOKEN_SOURCE'] = 'hosts.yml'
        t = self.offer()
        t.send(b'y')
        self.unlock(t)
        self.login(t)
        out = t.finish()
        self.assertIn('Authentication credentials saved in plain text', out)
        self.assertIn('configuration file path means plaintext storage', out)

    def test_linux_login_uses_tty_outside_install_log(self):
        self.env['TEST_OS'] = 'Linux'
        self.f.script('getent', 'printf "tester:x:501:501::%s:/bin/bash\\n" "$HOME"')
        self.f.script('dpkg-query', 'exit 1')
        t = self.offer(piped_input=True)
        t.send(b'y')
        self.login(t)
        self.assertIn('Git credential helper verified.', t.finish())
        self.assertNotIn('security ', self.calls())
        log = (self.f.home / 'vps-setup.log').read_text()
        self.assertIn('Results', log)
        self.assertNotIn('DEVICE-CODE', log)
        self.assertNotIn('Logged in as tester', log)
        self.assert_install_preserved()

    def test_noninteractive_modes_and_noop_do_not_authenticate(self):
        for args in [('--check',), ('--select', 'gh', '--dry-run'),
                     ('--select', 'shell', '--yes'), ('--select', 'none', '--yes')]:
            out = self.f.run_setup(*args)
            self.assertNotIn('Set up GitHub authentication now?', out)
        t = self.terminal('--select', 'shell')
        self.assertIn('No changes selected.', t.finish())
        self.assertEqual(self.calls(), '')

    def test_missing_gh_and_failed_install_do_not_offer_login(self):
        (self.f.state / 'tool-gh').unlink()
        t = self.terminal('--select', 'shell')
        t.expect('n Cancel')
        t.send(b'y')
        self.assertNotIn('Set up GitHub authentication now?', t.finish())
        self.env['FAIL_INSTALL'] = 'gh'
        t = self.terminal('--select', 'gh')
        t.expect('n Cancel')
        t.send(b'y')
        self.assertNotIn('Set up GitHub authentication now?', t.finish(expected=1))
        self.assertEqual(self.calls(), '')

    def test_documented_flow_keeps_working_authentication(self):
        (self.f.state / 'authenticated').touch()
        self.documented_login().finish()
        self.assertNotIn('security ', self.calls())
        self.assertNotIn('gh auth login', self.calls())
        self.assertIn('gh auth setup-git', self.calls())

    def test_documented_flow_rechecks_auth_after_default_keychain_unlock(self):
        self.env['UNLOCK_RESTORES_AUTH'] = '1'
        t = self.documented_login()
        self.unlock(t)
        t.finish()
        self.assertIn('security unlock-keychain\n', self.calls())
        self.assertNotIn('gh auth login', self.calls())
        self.assertIn('gh auth setup-git', self.calls())

    def test_documented_flow_stops_after_failed_unlock(self):
        self.env['FAIL_UNLOCK'] = '1'
        t = self.documented_login()
        self.unlock(t)
        t.finish(expected=1)
        self.assertNotIn('gh auth login', self.calls())
        self.assertNotIn('gh auth setup-git', self.calls())

    def test_documented_flow_checks_environment_without_replacing_it(self):
        for valid in ['0', '1']:
            with self.subTest(valid=valid):
                self.env.update(GH_TOKEN='test-env-token', ENV_AUTH_VALID=valid)
                out = self.documented_login().finish(expected=1 - int(valid))
                self.assertNotIn('test-env-token', out + self.calls())
                self.assertNotIn('security ', self.calls())
                self.assertNotIn('gh auth login', self.calls())
                self.assertEqual('gh auth setup-git' in self.calls(), valid == '1')

    def test_documented_flow_logs_in_only_when_auth_is_still_unavailable(self):
        t = self.documented_login()
        self.unlock(t)
        self.login(t)
        t.finish()
        self.assertIn('gh auth login --hostname github.com --git-protocol https --web', self.calls())
        self.assertIn('gh auth setup-git', self.calls())

    def test_documented_flow_skips_keychain_on_linux(self):
        self.env['TEST_OS'] = 'Linux'
        t = self.documented_login()
        self.login(t)
        t.finish()
        self.assertNotIn('security ', self.calls())
        self.assertIn('gh auth setup-git', self.calls())


if __name__ == '__main__':
    unittest.main(verbosity=2)
