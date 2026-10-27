"""Exercise the real setup engine with isolated systemd and privileged writes."""
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('linux_fixture', ROOT / 'tests/test-linux-onboarding.py')
linux = importlib.util.module_from_spec(spec)
spec.loader.exec_module(linux)


class TailscaleHardening(unittest.TestCase):
    def setUp(self):
        harness = linux.LinuxOnboarding()
        harness.setUp()
        self.addCleanup(harness.doCleanups)
        self.f = harness.f
        self.config = self.f.state / 'dropin'
        self.f.script('sudo', r'''printf 'sudo %s\n' "$1" >> "$TEST_STATE/calls"
case "$1" in
 -v) exit 0 ;;
 cmp) exec cmp -s "$3" "$TEST_STATE/dropin" ;;
 install)
   [ "${FAIL_WRITE:-0}" = 0 ] || exit 23
   [ "$6" = /etc/systemd/system/tailscaled.service.d/90-vps-setup-no-forwarding.conf ] || exit 91
   cp "$5" "$TEST_STATE/dropin" ;;
 systemctl) shift; exec systemctl "$@" ;;
 sh) [ -f "$TEST_STATE/runtime-enabled" ] ;;
 *) echo "forbidden sudo operation" >> "$TEST_STATE/forbidden"; exit 90 ;;
esac''')
        self.f.script('systemctl', r'''printf 'systemctl %s\n' "$*" >> "$TEST_STATE/calls"
case "$1" in
 show)
   case "$3" in
    --property=LoadState) echo "${TEST_LOAD_STATE:-loaded}" ;;
    --property=MainPID) echo 123 ;;
    *) exit 90 ;;
   esac ;;
 is-active) [ "${TEST_ACTIVE:-1}" = 1 ] ;;
 daemon-reload) [ "${FAIL_RELOAD:-0}" = 0 ] ;;
 restart)
   [ "${FAIL_RESTART:-0}" = 0 ] || exit 23
   [ "${TEST_CONFLICT:-0}" = 1 ] || touch "$TEST_STATE/runtime-enabled" ;;
 *) echo "forbidden service operation" >> "$TEST_STATE/forbidden"; exit 90 ;;
esac''')

    def apply(self, **env):
        return self.f.run_setup('--select', 'tailscale-hardening', '--yes', **env)

    def test_existing_install_apply_rerun_and_runtime_drift(self):
        out = self.apply()
        self.assertIn('disabled in the running daemon', out)
        self.assertIn('Environment="TS_SSH_DISABLE_FORWARDING=1"', self.config.read_text())
        self.assertNotIn('apt-get', self.f.calls())
        self.assertNotIn('curl', self.f.calls())
        before = self.config.stat().st_mtime_ns
        (self.f.state / 'calls').write_text('')
        self.apply()
        self.assertEqual(before, self.config.stat().st_mtime_ns)
        self.assertNotIn('systemctl restart', self.f.calls())
        (self.f.state / 'runtime-enabled').unlink()
        self.apply()
        self.assertIn('systemctl restart tailscaled.service', self.f.calls())

    def test_stopped_service_is_not_started(self):
        out = self.apply(TEST_ACTIVE='0')
        self.assertTrue(self.config.exists())
        self.assertIn('service left stopped', out)
        self.assertNotIn('systemctl restart', self.f.calls())

    def test_absent_unit_is_failure_without_writing(self):
        self.apply(TEST_LOAD_STATE='not-found', ok=False)
        self.assertFalse(self.config.exists())
        self.assertNotIn('daemon-reload', self.f.calls())

    def test_write_reload_and_restart_failures_are_not_success(self):
        for failure in ['FAIL_WRITE', 'FAIL_RELOAD', 'FAIL_RESTART']:
            with self.subTest(failure=failure):
                out = self.apply(ok=False, **{failure: '1'})
                self.assertNotIn('disabled in the running daemon', out)
                self.assertFalse((self.f.config / 'selection.txt').exists())

    def test_environment_override_fails_verification(self):
        out = self.apply(TEST_CONFLICT='1', ok=False)
        self.assertIn('could not be verified', out)
        self.assertFalse((self.f.config / 'selection.txt').exists())

    def test_previews_do_not_call_systemd_or_sudo(self):
        for flag in ['--check', '--dry-run']:
            out = self.f.run_setup('--select', 'tailscale-hardening', flag)
            self.assertIn('forwarding', out)
        self.assertEqual(self.f.calls(), '')
        self.assertFalse(self.config.exists())

    def test_macos_does_not_offer_linux_mitigation(self):
        self.f.run_setup('--select', 'tailscale-hardening', '--dry-run', TEST_OS='Darwin', ok=False)
        self.assertEqual(self.f.calls(), '')


if __name__ == '__main__':
    unittest.main()
