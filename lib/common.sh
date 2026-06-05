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

# Bail early on non-apt systems.
require_apt() {
  if ! have apt-get; then
    echo "This script targets Debian/Ubuntu (apt). Adapt it for your distro." >&2
    exit 1
  fi
}

# --- settings (sane defaults; override via env) ---------------------------
NVM_VERSION="${NVM_VERSION:-v0.40.5}"   # pinned nvm release
