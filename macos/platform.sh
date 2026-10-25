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
    if "$BREW_BIN" --version >/dev/null 2>&1; then eval "$("$BREW_BIN" shellenv)"
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

platform_manual() {
  printf '\nManual steps (not performed or tested):\n'
  printf '  • System Settings > General > Sharing: Remote Login / optional Screen Sharing; choose allowed users.\n'
  printf '  • System Settings > Energy: choose sleep and power-failure settings yourself.\n'
  printf '  • For a NEW Homebrew Tailscale install only, start it when ready: sudo brew services start tailscale.\n'
  printf '  • Sign in to Tailscale, GitHub and selected agents if needed; keep existing credentials.\n'
  printf '  • Open a new shell after configuration changes. tmux sessions do not survive reboots.\n'
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
  if [ "$NEED_BREW" = 1 ]; then printf '  Homebrew dependency: %s\n' "${BREW_BIN:-install once}"; fi
  printf 'Existing tools and Tailscale services are kept. Power and Sharing are manual.\n'
}
platform_preflight() {
  if [ "$NEED_BREW" = 1 ]; then
    [ "$CLT_READY" = 1 ] || die 'Finish xcode-select --install first; no changes applied'
    [ "$BREW_BROKEN" = 0 ] || die 'Repair existing Homebrew first; no changes applied'
  fi
}
platform_prepare() {
  export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_UPGRADE=1
  if [ "$NEED_BREW" = 1 ]; then platform_ensure_brew; fi
}
platform_install_tool() { "$BREW_BIN" install --formula "$1"; }
platform_apply_extra() { :; }
