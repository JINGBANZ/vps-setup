"""Gum loader and real keyboard tests; provisioning commands remain isolated fakes."""
import fcntl
import hashlib
import importlib.util
import io
import os
from pathlib import Path
import pty
import select
import struct
import subprocess
import tarfile
import termios
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('mac_fixture', ROOT / 'tests/test-macos-install.py')
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)
REAL_GUM = os.environ.get('GUM_TEST_BIN', '')


class Terminal:
    def __init__(self, env, *args, piped_input=False):
        self.master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 38, 110, 0, 0))

        def session():
            os.setsid()
            fcntl.ioctl(slave, termios.TIOCSCTTY, 0)

        self.proc = subprocess.Popen(['/bin/bash', str(ROOT / 'setup.sh'), *args],
                                     stdin=subprocess.DEVNULL if piped_input else slave,
                                     stdout=slave, stderr=slave, env=env, preexec_fn=session)
        os.close(slave)
        self.output = b''
        self.cursor = 0

    def read(self):
        if select.select([self.master], [], [], 0.1)[0]:
            try:
                chunk = os.read(self.master, 65536)
            except OSError:
                return False
            self.output += chunk
            # Answer terminal queries; no real terminal emulator in CI.
            if b'\x1b[6n' in chunk:
                self.send(b'\x1b[1;1R')
            if b'\x1b]11;?' in chunk:
                self.send(b'\x1b]11;rgb:0000/0000/0000\x1b\\')
            return bool(chunk)
        return self.proc.poll() is None

    def expect(self, text):
        needle = text.encode()
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline:
            index = self.output.find(needle, self.cursor)
            if index >= 0:
                self.cursor = index + len(needle)
                return
            if not self.read():
                break
        raise AssertionError(f'Missing {text!r}:\n{self.output.decode(errors="replace")}')

    def menu(self, title):
        self.expect(title)
        self.expect('ctrl+a select all')  # Wait for Gum's rendered menu, not the plain header.

    def send(self, data):
        os.write(self.master, data)

    def finish(self, expected=0):
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline and self.read():
            pass
        self.proc.wait(timeout=3)
        if self.proc.returncode != expected:
            raise AssertionError(self.output.decode(errors='replace'))
        return self.output.decode(errors='replace')

    def close(self):
        if self.proc.poll() is None:
            self.proc.kill()
            self.proc.wait()
        os.close(self.master)


class GumTests(unittest.TestCase):
    def setUp(self):
        self.f = fixture.MacSetup()
        self.f.setUp()
        self.addCleanup(self.f.doCleanups)
        self.env = dict(self.f.env, VPS_SETUP_UI='auto', TERM='xterm-256color', NO_COLOR='1')

    def terminal(self, *args, **kwargs):
        term = Terminal(self.env, *args, **kwargs)
        self.addCleanup(term.close)
        return term

    def use_real_gum(self):
        if not REAL_GUM:
            self.skipTest('Set GUM_TEST_BIN to the verified pinned Gum binary (required in CI)')
        self.assertTrue(Path(REAL_GUM).is_file())
        (self.f.bin / 'gum').symlink_to(REAL_GUM)

    def assert_no_install(self):
        self.assertNotIn('brew install', self.f.calls())
        self.assertNotIn('curl ', self.f.calls())
        self.assertFalse((self.f.state / 'forbidden').exists())

    def test_keyboard_arrows_space_and_cancel(self):
        self.use_real_gum()
        before = self.f.snapshot()
        t = self.terminal()
        t.menu('Choose tools to install')
        t.send(b'\x1b[B')
        t.expect('> [ ] Bun')
        t.send(b' ')
        t.expect('> [x] Bun')
        t.send(b'\x1b[A')
        t.expect('> [ ] Node.js / nvm')
        t.send(b' ')
        t.expect('> [x] Node.js / nvm')
        t.send(b' ')
        t.expect('> [ ] Node.js / nvm')
        t.send(b'\r')
        t.menu('Choose configuration updates')
        t.send(b' ')  # Deselect shortcut; shell is a fixed dependency of Bun.
        t.expect('> [ ] Session shortcut: t')
        t.send(b'\r')
        t.expect('n Cancel')
        t.send(b'\r')  # Cancel is the default confirmation.
        out = t.finish()
        self.assertIn('bun: install missing tool', out)
        self.assertNotIn('node: install missing tool', out)
        self.assertNotIn('shortcut: configure', out)
        self.assertIn('shell: configure', out)
        self.assertNotIn('[x] Tailscale', out)
        self.assertNotIn('[ ] Git', out)
        self.assertEqual(before, self.f.snapshot())
        self.assert_no_install()

    def test_apply_defaults_then_locked_rerun(self):
        self.use_real_gum()
        (self.f.state / 'tool-mosh').unlink()
        t = self.terminal()
        t.menu('Choose tools to install')
        self.assertIn(b'[x] Mosh', t.output)
        t.send(b'\r')
        t.menu('Choose configuration updates')
        t.send(b'\r')
        t.expect('n Cancel')
        t.send(b'\x1b[D')  # Move from Cancel to Install.
        time.sleep(0.1)
        t.send(b'\r')
        out = t.finish()
        self.assertIn('Installed — local version checked', out)
        self.assertIn('brew install --formula mosh', self.f.calls())
        before = self.f.snapshot()
        (self.f.state / 'calls').write_text('')
        t = self.terminal()
        t.menu('Choose tools to install')
        self.assertNotIn(b'[x] Mosh', t.output)
        self.assertNotIn(b'[ ] Mosh', t.output)
        t.send(b'\r')  # No missing tools selected; current configuration is skipped.
        t.expect('n Cancel')
        t.send(b'\r')
        t.finish()
        self.assertEqual(before, self.f.snapshot())
        self.assert_no_install()

    def test_empty_selection_and_piped_stdin(self):
        self.use_real_gum()
        (self.f.state / 'tool-tmux').unlink()
        before = self.f.snapshot()
        t = self.terminal(piped_input=True)
        t.menu('Choose tools to install')
        t.send(b'\x01')
        t.expect('[x] Bun')
        t.send(b'\x01')
        t.expect('[ ] tmux')
        t.send(b'\r')  # No tools; the pending shortcut must not reselect tmux yet.
        t.menu('Choose configuration updates')
        t.send(b'\x01')  # Ctrl-A deselects both configuration entries.
        t.expect('[ ] Session shortcut: t')
        t.send(b'\r')
        t.expect('n Cancel')
        t.send(b'y')
        out = t.finish()
        self.assertIn('No eligible items selected', out)
        self.assertEqual(before, self.f.snapshot())
        self.assert_no_install()

    def test_escape_and_ctrl_c_never_apply(self):
        self.use_real_gum()
        before = self.f.snapshot()
        for key in [b'\x1b', b'\x03']:
            t = self.terminal()
            t.menu('Choose tools to install')
            t.send(key)
            self.assertIn('no changes applied', t.finish())
        self.assertEqual(before, self.f.snapshot())
        self.assert_no_install()

    def test_all_present_and_broken_items_skip_checklists(self):
        self.use_real_gum()
        self.f.run_setup('--select', 'shortcut', '--yes')
        self.f.install('node', 'bun')
        (self.f.state / 'broken-codex').touch()
        (self.f.state / 'calls').write_text('')
        before = self.f.snapshot()
        t = self.terminal()
        t.expect('n Cancel')
        t.send(b'\r')
        out = t.finish()
        self.assertIn('broken — Unusable', out)
        self.assertNotIn('Choose tools to install', out)
        self.assertNotIn('Choose configuration updates', out)
        self.assertEqual(before, self.f.snapshot())
        self.assert_no_install()

    def test_noninteractive_modes_never_fetch_ui(self):
        for args in [('--check',), ('--select', 'codex', '--dry-run'), ('--select', 'none', '--yes')]:
            self.f.run_setup(*args, VPS_SETUP_UI='auto')
        self.assert_no_install()

    def test_unavailable_gum_stops_before_mutation(self):
        self.f.script('gum', 'exit 1')
        self.f.script('curl', 'echo failed-ui-download >> "$TEST_STATE/calls"; exit 22')
        self.f.script('uname', 'case "$1" in -s) echo Darwin ;; -m) echo arm64 ;; esac')
        tempdir = self.f.base / 'ui-temp'
        tempdir.mkdir()
        self.env['TMPDIR'] = str(tempdir)
        before = self.f.snapshot()
        t = self.terminal()
        t.expect('Cannot prepare Gum')
        out = t.finish(expected=1)
        self.assertNotIn('Toggle eligible numbers', out)
        self.assertEqual(list(tempdir.iterdir()), [])
        self.assertEqual(before, self.f.snapshot())
        self.assertIn('failed-ui-download', self.f.calls())

    def test_dumb_terminal_stops_without_download(self):
        self.env['TERM'] = 'dumb'
        t = self.terminal()
        t.expect('Cannot prepare Gum')
        t.finish(expected=1)
        self.assert_no_install()

    def test_verified_download_cleanup_and_rejection(self):
        archive = self.f.base / 'fixture.tar.gz'
        executable = b'#!/bin/bash\ntouch "$TEST_STATE/ui-executed"\necho "gum version v0.17.0 (fixture)"\n'
        with tarfile.open(archive, 'w:gz') as tar:
            info = tarfile.TarInfo('fixture/gum')
            info.size = len(executable)
            info.mode = 0o700
            tar.addfile(info, io.BytesIO(executable))
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        self.f.script('curl', '''while [ "$1" != -o ]; do shift; done
cp "$UI_TEST_ARCHIVE" "$2"''')
        tempdir = self.f.base / 'ui-temp'
        tempdir.mkdir()
        script = '''. "$1/lib/terminal-ui.sh"
trap ui_cleanup EXIT
ui_gum_asset() { UI_GUM_ARCHIVE=fixture; UI_GUM_SHA="$UI_TEST_SHA"; }
ui_gum_download
'''
        for sha, success in [('0' * 64, False), (digest, True)]:
            result = subprocess.run(['/bin/bash', '-eu', '-c', script, '_', str(ROOT)],
                                    env=dict(self.env, TMPDIR=str(tempdir), UI_TEST_ARCHIVE=str(archive), UI_TEST_SHA=sha),
                                    capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode == 0, success, result.stderr)
            self.assertEqual((self.f.state / 'ui-executed').exists(), success)
            self.assertEqual(list(tempdir.iterdir()), [])


if __name__ == '__main__':
    unittest.main(verbosity=2)
