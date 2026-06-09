#!/usr/bin/env bash
# test-fresh-install.sh — end-to-end smoke test of the non-interactive apt path
# on a FRESH box, run as root inside a minimal Ubuntu container. It reproduces
# the original failure conditions:
#   * needrestart's apt hook is active (the package that hung the box), and
#   * stdin is NOT a TTY (the `curl | sudo bash` pipe).
# With the lib/common.sh fix, a real install via the repo's apt_get wrapper must
# complete promptly instead of blocking on a hidden needrestart/debconf prompt.
# A `timeout` turns any hang into a clear exit-124 failure rather than a stuck job.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ "$(id -u)" -ne 0 ]; then
  echo "SKIP: must run as root in a container (got uid $(id -u))"
  exit 0
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null

# No init system in the container: stop service postinst scripts from trying to
# start daemons (which would fail and muddy the result). 101 = "do not start".
printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
chmod +x /usr/sbin/policy-rc.d

# Activate the exact apt hook that hung the original box.
apt-get install -y needrestart >/dev/null

# The real install, through the repo's wrapper, with NO TTY on stdin and a hard
# time budget. If the fix regresses, needrestart prompts, this blocks, and
# timeout kills it with exit 124. (Functions can't be exported, so re-source
# lib/common.sh inside the timed subshell to get apt_get.)
if timeout 240 bash -c '. "$1/lib/common.sh"; apt_get install -y fail2ban' _ "$REPO_ROOT" </dev/null; then
  :
else
  rc=$?
  if [ "$rc" -eq 124 ]; then
    echo "FAIL: install hung — needrestart/debconf prompted with no TTY (exit 124)" >&2
  else
    echo "FAIL: install errored (exit $rc)" >&2
  fi
  exit 1
fi

dpkg -s fail2ban >/dev/null 2>&1 || { echo "FAIL: fail2ban not installed" >&2; exit 1; }
echo "PASS: fresh-box non-interactive install completed without hanging"
