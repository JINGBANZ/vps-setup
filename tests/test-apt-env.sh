#!/usr/bin/env bash
# test-apt-env.sh — verify the apt_get wrapper in lib/common.sh forces apt fully
# non-interactive. This is the unit-level guard for the fresh-box install hang:
# debconf/needrestart trying to open a dialog with no TTY (the `curl | sudo bash`
# case) and blocking forever.
#
# It installs nothing. A stub `apt-get` on PATH records the environment the
# wrapper invokes apt with, so the check is fast, offline, and deterministic.
# Run as root so SUDO="" and the wrapper calls apt-get directly (matching the
# `sudo bash` path); under sudo the stub on a temp PATH would be unreachable.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

# Stub apt-get: dump the environment it was called with, then succeed.
cat > "$workdir/apt-get" <<EOF
#!/usr/bin/env bash
env > "$workdir/captured-env"
exit 0
EOF
chmod +x "$workdir/apt-get"
export PATH="$workdir:$PATH"

# Source the real helpers and invoke the real wrapper.
# shellcheck source=lib/common.sh
. "$REPO_ROOT/lib/common.sh"
apt_get install -y some-package

[ -f "$workdir/captured-env" ] || fail "apt_get never invoked apt-get"
grep -qx 'DEBIAN_FRONTEND=noninteractive' "$workdir/captured-env" \
  || fail "DEBIAN_FRONTEND=noninteractive not passed through to apt-get"
grep -qx 'NEEDRESTART_MODE=a' "$workdir/captured-env" \
  || fail "NEEDRESTART_MODE=a not passed through to apt-get"

echo "PASS: apt_get forces non-interactive apt (DEBIAN_FRONTEND + NEEDRESTART_MODE)"
