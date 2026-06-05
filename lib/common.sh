#!/usr/bin/env bash
#
# lib/common.sh — shared helpers, config knobs, and environment detection.
# Sourced by setup.sh before any module. Not meant to be run directly.
#
# Modules rely on everything defined here: log/skip/ok/warn, SUDO, have(),
# TARGET_USER/TARGET_HOME, write_config, and the configurable knobs below.

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

# The user we install user-level tools for / harden SSH for. Under sudo this is
# the original login user, not root.
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

# write_config <path> [mode]  — desired file content is read from stdin.
# Converges the file to that content, but only WRITES when it actually differs.
# Returns 0 if it changed the file, 1 if it was already up to date — so callers
# can reload/restart services only on a real change (no needless churn on re-run).
# For NON-SECRET config only: the content briefly lives in a user-owned temp file.
#
# MUST be used in a conditional (`if write_config ...; then`) — the "unchanged"
# return of 1 would otherwise abort the script under `set -e`.
write_config() {
  local path="$1" mode="${2:-0644}" tmp
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' RETURN   # clean up even if interrupted mid-run
  cat > "$tmp"
  $SUDO cmp -s "$tmp" "$path" 2>/dev/null && return 1   # already up to date
  $SUDO install -D -m "$mode" "$tmp" "$path"
  return 0                                              # changed
}

# --- settings (sane defaults; rarely changed) -----------------------------
# These are configuration values, not feature toggles — opt-in/out of features
# happens through interactive prompts, not flags.
NVM_VERSION="${NVM_VERSION:-v0.40.5}"      # pinned nvm release
SSH_PORT="${SSH_PORT:-22}"                  # firewall/fail2ban target port

# --- interactivity --------------------------------------------------------
# Optional features ask before acting. Prompts read/write /dev/tty so they work
# even under the tee redirect and when piped (curl | bash). With no terminal
# (cron/CI) INTERACTIVE=0 and every prompt falls back to its default.
INTERACTIVE=0
if { : </dev/tty; } 2>/dev/null; then INTERACTIVE=1; fi

# ask_yes_no "Question?" [default y|n]  -> exit 0 = yes, 1 = no
ask_yes_no() {
  local prompt="$1" default="${2:-n}" reply hint
  if [ "$INTERACTIVE" -ne 1 ]; then [ "$default" = "y" ]; return; fi
  hint="[y/N]"; [ "$default" = "y" ] && hint="[Y/n]"
  printf '\033[1;36m??\033[0m %s %s ' "$prompt" "$hint" >/dev/tty
  read -r reply </dev/tty || reply=""
  reply="${reply:-$default}"
  case "$reply" in [Yy]*) return 0;; *) return 1;; esac
}

# ask_value "Prompt" [default]  -> echoes the entered value (or default)
ask_value() {
  local prompt="$1" default="${2:-}" reply
  if [ "$INTERACTIVE" -ne 1 ]; then printf '%s' "$default"; return; fi
  if [ -n "$default" ]; then printf '\033[1;36m??\033[0m %s [%s] ' "$prompt" "$default" >/dev/tty
  else printf '\033[1;36m??\033[0m %s ' "$prompt" >/dev/tty; fi
  read -r reply </dev/tty || reply=""
  printf '%s' "${reply:-$default}"
}

# Only lines starting with a known key type are real keys (skips comments/blanks).
SSH_KEY_RE='^(ssh-(ed25519|rsa|dss)|ecdsa-sha2-|sk-ssh-ed25519|sk-ecdsa-sha2-)'

# Resolve usable SSH public key(s) once and cache them (newline-separated, may be
# several). Priority: 1. cached  2. root's authorized_keys  3. target user's
#   4. interactive paste (validated). Only valid key lines are returned.
SSH_PUBKEY=""
get_ssh_public_key() {
  if [ -n "$SSH_PUBKEY" ]; then printf '%s' "$SSH_PUBKEY"; return; fi
  local k="" paste
  if $SUDO test -s /root/.ssh/authorized_keys 2>/dev/null; then
    k="$($SUDO grep -E "$SSH_KEY_RE" /root/.ssh/authorized_keys 2>/dev/null || true)"
  fi
  if [ -z "$k" ] && [ -s "$TARGET_HOME/.ssh/authorized_keys" ]; then
    k="$(grep -E "$SSH_KEY_RE" "$TARGET_HOME/.ssh/authorized_keys" 2>/dev/null || true)"
  fi
  if [ -z "$k" ] && [ "$INTERACTIVE" -eq 1 ]; then
    while :; do
      paste="$(ask_value '   Paste the SSH PUBLIC key to authorize (e.g. ssh-ed25519 AAAA...):' '')"
      [ -z "$paste" ] && break
      # Validate the paste really is a public key before accepting it.
      if printf '%s\n' "$paste" | ssh-keygen -l -f - >/dev/null 2>&1; then k="$paste"; break; fi
      warn "That doesn't look like a valid SSH public key — try again (blank to skip)."
    done
  fi
  SSH_PUBKEY="$k"
  printf '%s' "$k"
}

# install_authorized_key <user> <pubkeys>  -> append each key line (deduped),
# fix perms (700 dir / 600 file, owned by user). Idempotent.
install_authorized_key() {
  local user="$1" keys="$2" home line ak
  home="$(getent passwd "$user" | cut -d: -f6)"
  [ -n "$home" ] || return 1
  ak="$home/.ssh/authorized_keys"
  $SUDO install -d -m 700 -o "$user" -g "$user" "$home/.ssh"
  $SUDO touch "$ak"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    $SUDO grep -qsF "$line" "$ak" 2>/dev/null && continue
    printf '%s\n' "$line" | $SUDO tee -a "$ak" >/dev/null
  done <<EOF
$keys
EOF
  $SUDO chown "$user:$user" "$ak"
  $SUDO chmod 600 "$ak"
}
