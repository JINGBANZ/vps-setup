#!/usr/bin/env bash
# macOS desktop provisioning. Invoked by ../setup.sh; compatible with Bash 3.2.
# Run as your normal account. Only power settings and the Tailscale system
# service use sudo; Homebrew, runtimes and agents always belong to you.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ "$(uname -s)" != Darwin ]; then
  echo "macos/setup.sh requires macOS." >&2
  exit 1
fi
if [ "$(id -u)" -eq 0 ]; then
  echo "On macOS, run bash setup.sh as your normal user WITHOUT sudo." >&2
  exit 1
fi

# shellcheck source=lib/common.sh
. "$REPO_ROOT/lib/common.sh"
MAC_ALWAYS_ON="${MAC_ALWAYS_ON:-1}"
MAC_TAILSCALE="${MAC_TAILSCALE:-1}"
case "$MAC_ALWAYS_ON:$MAC_TAILSCALE" in
  0:0|0:1|1:0|1:1) ;;
  *) warn "MAC_ALWAYS_ON and MAC_TAILSCALE must be 0 or 1"; exit 1 ;;
esac
if [ -n "${GH_RUNNER_REPO:-}" ] || [ "${DEV_POSTGRES:-0}" != 0 ]; then
  warn "GH_RUNNER_REPO and DEV_POSTGRES are Linux-only; unset them for macOS."
  exit 1
fi
case "$WORKSPACE_DIR" in
  /*) ;;
  *) warn "WORKSPACE_DIR must be an absolute path"; exit 1 ;;
esac
if ! xcode-select -p >/dev/null 2>&1; then
  warn "Install Apple's Command Line Tools with xcode-select --install, then rerun."
  exit 1
fi

# Do not replace a different Tailscale installation or interrupt its tunnel.
if [ "$MAC_TAILSCALE" = 1 ]; then
  for app in /Applications/Tailscale.app "$HOME/Applications/Tailscale.app"; do
    if [ -d "$app" ]; then
      warn "Found $app. Remove the GUI app and reboot before switching to tailscaled."
      warn "Or rerun with MAC_TAILSCALE=0 to keep your existing installation."
      exit 1
    fi
  done
  if launchctl print "gui/$(id -u)/homebrew.mxcl.tailscale" >/dev/null 2>&1; then
    warn "A user-level Tailscale service is loaded. Stop it locally with brew services stop tailscale, then rerun."
    exit 1
  fi
fi

LOGFILE="${LOGFILE:-$TARGET_HOME/vps-setup.log}"
exec > >(tee -a "$LOGFILE") 2>&1
log "macOS setup; logging to $LOGFILE"

# Homebrew can exist without being on a fresh SSH shell's PATH.
BREW_BIN="$(command -v brew || true)"
if [ -z "$BREW_BIN" ]; then
  for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [ -x "$candidate" ]; then BREW_BIN="$candidate"; break; fi
  done
fi
if [ -z "$BREW_BIN" ]; then
  log "Installing Homebrew as $TARGET_USER (may ask for your password)"
  installer="$(mktemp)"
  trap 'rm -f "$installer"' EXIT
  curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh -o "$installer"
  /bin/bash "$installer"
  rm -f "$installer"
  trap - EXIT
  for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [ -x "$candidate" ]; then BREW_BIN="$candidate"; break; fi
  done
fi
if [ -z "$BREW_BIN" ]; then
  warn "Homebrew was not found after installation; see https://brew.sh and rerun."
  exit 1
fi
eval "$("$BREW_BIN" shellenv)"
export PATH="$HOME/.local/bin:$HOME/.bun/bin:$PATH"

for formula in git tmux mosh gh; do
  if "$BREW_BIN" list --formula "$formula" >/dev/null 2>&1; then
    skip "$formula (Homebrew)"
  else
    "$BREW_BIN" install --formula "$formula"
  fi
done

CONFIG_DIR="$HOME/.config/vps-setup"
mkdir -p "$CONFIG_DIR" "$WORKSPACE_DIR"

# Use AC settings only; display sleep and battery settings are left alone.
if [ "$MAC_ALWAYS_ON" = 1 ]; then
  if [ ! -f "$CONFIG_DIR/power-settings-before.txt" ]; then
    (umask 077; pmset -g custom > "$CONFIG_DIR/power-settings-before.txt")
  fi
  power_settings="$(pmset -g custom)"
  power_caps="$(pmset -g cap)"
  for setting in sleep autorestart; do
    if [ "$setting" = sleep ]; then
      wanted=0
    else
      wanted=1
      if ! printf '%s\n' "$power_caps" | grep -Eq '^[[:space:]]*autorestart[[:space:]]*$'; then
        warn "Automatic power-on is not exposed by pmset on this Mac; check System Settings > Energy."
        continue
      fi
    fi
    current="$(printf '%s\n' "$power_settings" | awk -v key="$setting" '
      /^AC Power:/ { ac=1; next }
      /^[^[:space:]]/ { ac=0 }
      ac && $1 == key { print $2; exit }
    ')"
    if [ "$current" = "$wanted" ]; then
      skip "AC power: $setting=$wanted"
    else
      sudo pmset -c "$setting" "$wanted"
      ok "AC power: $setting=$wanted"
    fi
  done
else
  skip "Always-on power settings (MAC_ALWAYS_ON=0)"
fi

if [ "$MAC_TAILSCALE" = 1 ]; then
  # The upstream install-system-daemon command uses a different launchd label.
  if sudo launchctl print system/com.tailscale.tailscaled >/dev/null 2>&1; then
    warn "An upstream tailscaled daemon is loaded; keep it with MAC_TAILSCALE=0 or uninstall it before switching."
    exit 1
  fi
  if ! "$BREW_BIN" list --formula tailscale >/dev/null 2>&1; then
    "$BREW_BIN" install --formula tailscale
  fi
  # sudo is intentional: a LaunchDaemon starts at boot, a LaunchAgent at login.
  # brew services start is a no-op when the service is already running.
  sudo "$BREW_BIN" services start tailscale
  if ! sudo launchctl print system/homebrew.mxcl.tailscale >/dev/null 2>&1; then
    warn "Tailscale's system service did not load. Check sudo brew services info tailscale."
    exit 1
  fi
  ok "Tailscale system service loaded; authenticate manually with sudo tailscale up"
else
  skip "Tailscale installation/service (MAC_TAILSCALE=0)"
fi

# The official runtime/agent installers support macOS as well as Linux.
# We manage nvm's startup snippet explicitly for both zsh and bash below.
export PROFILE=/dev/null
# shellcheck source=modules/60-node-bun.sh
. "$REPO_ROOT/modules/60-node-bun.sh"
# shellcheck source=modules/70-agents.sh
. "$REPO_ROOT/modules/70-agents.sh"

TMUX_RC_FILE="$CONFIG_DIR/tmux.sh"
# shellcheck source=modules/80-tmux.sh
. "$REPO_ROOT/modules/80-tmux.sh"

# Keep generated configuration separate from the user's shell customizations.
printf -v brew_quoted '%q' "$BREW_BIN"
printf -v nvm_quoted '%q' "$NVM_DIR"
printf -v tmux_quoted '%q' "$TMUX_RC_FILE"
env_file="$CONFIG_DIR/env.sh"
env_tmp="$(mktemp)"
cat > "$env_tmp" <<EOF
# Managed by vps-setup/macOS. Sourced by interactive/login zsh and bash.
eval "\$($brew_quoted shellenv)"
export PATH="\$HOME/.local/bin:\$HOME/.bun/bin:\$PATH"
export NVM_DIR=$nvm_quoted
[ ! -s "\$NVM_DIR/nvm.sh" ] || . "\$NVM_DIR/nvm.sh"
. $tmux_quoted
EOF
if ! cmp -s "$env_tmp" "$env_file"; then
  cat "$env_tmp" > "$env_file"
fi
rm -f "$env_tmp"

printf -v env_quoted '%q' "$env_file"
source_line="[ ! -f $env_quoted ] || . $env_quoted # vps-setup:macos"
zsh_dir="${ZDOTDIR:-$HOME}"
mkdir -p "$zsh_dir"
# Bash reads only the first existing login profile; do not shadow .profile.
bash_profile="$HOME/.bash_profile"
for profile in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
  if [ -f "$profile" ]; then bash_profile="$profile"; break; fi
done
for profile in "$zsh_dir/.zprofile" "$zsh_dir/.zshrc" "$bash_profile" "$HOME/.bashrc"; do
  if ! grep -Fqx "$source_line" "$profile" 2>/dev/null; then
    printf '\n%s\n' "$source_line" >> "$profile"
  fi
done

log "macOS tools installed. Finish access setup before leaving the mini unattended."
cat <<'EOF'

Open a new terminal, or: source ~/.config/vps-setup/env.sh

In System Settings > General > Sharing:
  - Remote Login: On; allow only your account (SSH).
  - Screen Sharing: On; allow only your account (optional desktop access).

Interactive authentication (not captured in this setup log):
  sudo tailscale up
  gh auth login
  claude
  codex

From your laptop with Tailscale connected:
  ssh YOUR_MAC_USER@YOUR_MINI_TAILSCALE_IP
  t my-task
  codex                    # or claude
Detach with Ctrl-b, then d; reconnect with t my-task.

tmux survives SSH disconnects, not reboots. FileVault can require unlocking
after a restart before this Tailscale service can start. Wi-Fi works for normal
use; test recovery from outside your home network before relying on it.
See macos/README.md for SSH keys, Screen Sharing and reboot recovery.
EOF
