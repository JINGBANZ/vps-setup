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
        if b"Toggle numbers" in output and not sent:
            os.write(master, b"none\n3,5\n\ncancel\n")
            sent = True
        if proc.poll() is not None:
            # Drain the PTY once more before checking output.
            continue
    proc.wait(timeout=5)
    text = output.decode(errors="replace")
    assert proc.returncode == 0, text
    for expected in ["Dependency added: tmux", "Dependency added: Remote Login",
                     "Type apply", "Cancelled; no changes applied"]:
        assert expected in text, (expected, text)
    print("PASS: interactive menu, dependencies, plan and cancellation")
finally:
    if proc.poll() is None:
        proc.kill()
        proc.wait()
    os.close(master)
