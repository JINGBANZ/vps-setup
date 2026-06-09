#!/usr/bin/env bash
#
# lib/common.sh — shared helpers and environment. Sourced by setup.sh before any
# module; not meant to be run directly.
#
# Modules rely on everything defined here: log/skip/ok/warn, SUDO, have(),
# TARGET_USER/TARGET_HOME, require_apt, and the settings near the bottom.

# Mark that common was loaded, so modules can refuse to run standalone.
_VPS_COMMON_LOADED=1

# --- pretty output --------------------------------------------------------
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
skip() { printf '\033[1;33m--\033[0m %s \033[1;33m(skipping)\033[0m\n' "$*"; }
ok()   { printf '\033[1;32mok\033[0m %s\n' "$*"; }
warn() { printf '\033[1;31m!!\033[0m %s\n' "$*"; }

# --- privilege & lookups --------------------------------------------------
# Use sudo only when we're not already root.
if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

have() { command -v "$1" >/dev/null 2>&1; }

# The user we install user-level tools for. Under sudo this is the original
# login user, not root.
TARGET_USER="${SUDO_USER:-$(id -un)}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[ -n "$TARGET_HOME" ] || TARGET_HOME="$HOME"

# --- non-interactive apt --------------------------------------------------
# Without these, the first real `apt-get install` on a fresh box hangs: debconf
# and needrestart try to open interactive dialogs, but under `curl … | sudo bash`
# stdin is the pipe, not a TTY, so the prompt waits forever with nothing able to
# answer it. Force every apt/dpkg/needrestart invocation fully non-interactive.
#   DEBIAN_FRONTEND=noninteractive  — debconf never prompts, uses defaults
#   NEEDRESTART_MODE=a              — needrestart auto-restarts the affected
#                                     services instead of showing its TUI menu,
#                                     so upgraded libraries actually take effect
#                                     (vs. NEEDRESTART_SUSPEND, which would skip
#                                     the check entirely and leave them stale).
# Exported so they reach apt run directly (root, SUDO="") and, via the `env`
# prefix below, apt run through sudo (which otherwise scrubs the environment).
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

# apt_get — wrapper that runs apt-get with the non-interactive env preserved
# across the sudo boundary. Modules should call this instead of `$SUDO apt-get`.
apt_get() {
  $SUDO env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get "$@"
}

# Bail early on non-apt systems.
require_apt() {
  if ! have apt-get; then
    echo "This script targets Debian/Ubuntu (apt). Adapt it for your distro." >&2
    exit 1
  fi
}

# write_config <path> [mode]  — desired file content is read from stdin.
# Converges the file to that content, but only WRITES when it actually differs.
# Returns 0 if it changed the file, 1 if it was already up to date — so callers
# can reload/restart services only on a real change (no needless churn on re-run).
# For NON-SECRET config only: the content briefly lives in a user-owned temp file.
#
# MUST be used in a conditional (`if write_config ...; then`) — the "unchanged"
# return of 1 would otherwise abort the script under `set -e`.
write_config() {
  local path="$1" mode="${2:-0644}" tmp rc=0
  tmp="$(mktemp)"
  cat > "$tmp"
  if $SUDO cmp -s "$tmp" "$path" 2>/dev/null; then
    rc=1                                   # already up to date
  else
    $SUDO install -D -m "$mode" "$tmp" "$path"   # rc stays 0: changed
  fi
  rm -f "$tmp"
  return "$rc"
}

# --- settings (sane defaults; override via env) ---------------------------
NVM_VERSION="${NVM_VERSION:-v0.40.5}"   # pinned nvm release
SSH_PORT="${SSH_PORT:-22}"               # firewall/fail2ban target port
