#!/usr/bin/env bash
# Adapter outputs are consumed by lib/onboarding.sh and lib/setup.sh.
# shellcheck disable=SC2034
# macOS adapter; shared onboarding lives in lib/onboarding*.sh.
platform_find_brew() {
  BREW_BIN="$(command -v brew || true)"
  if [ -z "$BREW_BIN" ]; then
    for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
      if [ -x "$candidate" ]; then BREW_BIN="$candidate"; break; fi
    done
  fi
  BREW_BROKEN=0
  if [ -n "$BREW_BIN" ]; then
    if "$BREW_BIN" --version >/dev/null 2>&1; then eval "$("$BREW_BIN" shellenv bash)"
    else BREW_BROKEN=1; fi
  fi
}

platform_ensure_brew() {
  local installer
  [ "$BREW_BROKEN" = 0 ] || die 'Existing Homebrew is unusable; repair it manually'
  if [ -z "$BREW_BIN" ]; then
    installer="$(mktemp)"
    if ! curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh -o "$installer"; then rm -f "$installer"; return 1; fi
    if ! /bin/bash "$installer"; then rm -f "$installer"; return 1; fi
    rm -f "$installer"
    platform_find_brew
  fi
  [ -n "$BREW_BIN" ] && [ "$BREW_BROKEN" = 0 ]
}

platform_next_steps() {
  if [ "${RESULTS[0]}" = Installed ]; then
    on_next_step 'Start Tailscale: sudo brew services start tailscale'
    on_next_step 'Tailscale sign-in: sudo tailscale up'
  fi
}

platform_init() {
  [ "$(id -u)" -ne 0 ] || die 'Run without sudo as your normal administrator user'
  [ -z "${GH_RUNNER_REPO:-}" ] && [ "${DEV_POSTGRES:-0}" = 0 ] || die 'PostgreSQL and Actions runner are Linux-only'
  case "${MAC_TAILSCALE:-1}" in 0|1) ;; *) die 'MAC_TAILSCALE must be 0 or 1' ;; esac
}
platform_discover() {
  CLT_READY=0; if xcode-select -p >/dev/null 2>&1; then CLT_READY=1; fi
  platform_find_brew
}
platform_detect_tool() {
  local id="$1" candidate
  if [ "$id" = tailscale ]; then
    for candidate in /Applications/Tailscale.app "$HOME/Applications/Tailscale.app" \
      /Library/LaunchDaemons/homebrew.mxcl.tailscale.plist \
      /Library/LaunchDaemons/com.tailscale.tailscaled.plist \
      "$HOME/Library/LaunchAgents/homebrew.mxcl.tailscale.plist"; do
      if [ -e "$candidate" ] || [ -L "$candidate" ]; then
        DETECTED=installed; DETAIL="Present: $candidate (kept; no service/auth checks)"; return 0
      fi
    done
  fi
  return 1
}
platform_detect_package() {
  local id="$1"
  if [ -n "$BREW_BIN" ] && [ "$BREW_BROKEN" = 0 ] && "$BREW_BIN" list --formula "$id" >/dev/null 2>&1; then
    if [ "$id" = tailscale ]; then DETECTED=installed; DETAIL='Homebrew formula present (kept, even if stopped)'
    else DETECTED=broken; DETAIL='Formula present but command unavailable; repair PATH manually'; fi
  fi
}
platform_inventory() { printf 'Homebrew dependency: %s\n' "${BREW_BIN:-not installed}"; }
platform_plan() {
  local id
  NEED_BREW=0
  for id in tailscale git gh tmux mosh; do if on_selected "$id"; then NEED_BREW=1; fi; done
  if [ "$NEED_BREW" = 1 ] && [ -z "$BREW_BIN" ]; then
    printf '  - Install Homebrew (required)\n'
  fi
}
platform_preflight() {
  local python_bin
  if on_selected preview-service; then
    python_bin="$(command -v python3 || true)"
    { [ -n "$python_bin" ] && [ "$python_bin:$CLT_READY" != /usr/bin/python3:0 ]; } || die 'Preview service requires Python 3 from Command Line Tools; no changes applied'
  fi
  if [ "$NEED_BREW" = 1 ]; then
    [ "$CLT_READY" = 1 ] || die 'Finish xcode-select --install first; no changes applied'
    [ "$BREW_BROKEN" = 0 ] || die 'Repair existing Homebrew first; no changes applied'
  fi
}
platform_prepare() {
  export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_UPGRADE=1
  if [ "$NEED_BREW" = 1 ]; then platform_ensure_brew; fi
}
platform_install_tool() {
  # The shared review already approved this tool and its dependencies.
  # Scope Homebrew's documented no-ask mode to this install, not future shells.
  HOMEBREW_NO_ASK=1 "$BREW_BIN" install --formula "$1"
}
platform_apply_extra() { :; }
