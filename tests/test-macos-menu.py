"""Drive the real Bash menu through a PTY; never provision the test host."""
import os
import pty
import select
import subprocess
import sys
import time

master, slave = pty.openpty()
proc = subprocess.Popen(["/bin/bash", sys.argv[1]], stdin=slave,
                        stdout=slave, stderr=slave, start_new_session=True)
os.close(slave)
output = b""
sent = False
deadline = time.monotonic() + 30
try:
    while time.monotonic() < deadline:
        if select.select([master], [], [], 0.1)[0]:
            try:
                chunk = os.read(master, 65536)
            except OSError:
                break
            if not chunk:
                break
            output += chunk
        if b"Toggle eligible numbers" in output and not sent:
            os.write(master, b"all\n1,6\nnone\ndefaults\n\ncancel\n")
            sent = True
        if proc.poll() is not None:
            # Drain the PTY once more before checking output.
            continue
    proc.wait(timeout=5)
    text = output.decode(errors="replace")
    assert proc.returncode == 0, text
    for expected in ["tailscale is locked", "codex is locked", "Type apply", "Cancelled; no changes applied"]:
        assert expected in text, (expected, text)
    for line in text.splitlines():
        if "LOCKED" in line:
            assert "[x]" not in line and "[ ]" not in line, line
    inventories = text.split('Local installation inventory')[1:]
    assert len(inventories) == 5, text
    # Initial/defaults leave runtimes off; all enables them; none clears all.
    for index in [0, 4]:
        assert '[ ] Node.js / nvm' in inventories[index], text
    assert '[x] Node.js / nvm' in inventories[1], text
    assert '[x]' not in inventories[3], text
    assert "ssh: install" not in text and "power: install" not in text
    print("PASS: locked rows, bulk choices, plan and cancellation")
finally:
    if proc.poll() is None:
        proc.kill()
        proc.wait()
    os.close(master)
