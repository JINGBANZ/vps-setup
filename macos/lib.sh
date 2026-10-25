#!/usr/bin/env bash
# macOS server installation helpers; compatible with Apple Bash 3.2.
COMPONENTS=(tailscale mosh tmux git gh codex claude node bun shortcut shell)
LABELS=('Tailscale' 'Mosh' 'tmux' 'Git' 'GitHub CLI' 'Codex' 'Claude Code' 'Node.js / nvm' 'Bun' 'Session shortcut: t' 'Shell integration')
STATES=(); DETAILS=(); RESULTS=()
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
mac_usage() {
  cat <<'EOF'
Usage on macOS: bash setup.sh [options] (without sudo)
  --check             Read-only local installation inventory.
  --dry-run           Read-only plan; no installation or connection probes.
  --select LIST       Comma-separated IDs, or none. Installed items stay locked.
  --yes               Apply an explicit --select list without menu confirmation.
  --help              Show help.
Tools: tailscale,mosh,tmux,git,gh,codex,claude,node,bun
Configuration: shortcut,shell
Node and Bun default off. Only missing tools and outdated configuration are selectable.
SSH, Screen Sharing, power and sign-in are manual checklist items.
EOF
}
mac_selected() { case "$SELECTED" in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
mac_select() { if ! mac_selected "$1"; then SELECTED="$SELECTED$1 "; fi; }
mac_deselect() { SELECTED="${SELECTED// $1 / }"; }
mac_selection_words() (
  # Split plain selection data without expanding patterns. Keep noglob inside
  # this subshell: nvm needs normal filename expansion to discover versions.
  set -f
  for word in ${1//,/ }; do printf '%s\n' "$word"; done
)
mac_parse_selection() {
  local id item known
  SELECTED=' '
  [ "$1" != none ] || return 0
  [ -n "$1" ] || die 'Empty selection; use none'
  while IFS= read -r id; do
    case "$id" in ssh|screen|power) die "$id is manual; remove it from --select" ;; esac
    known=0
    for item in "${COMPONENTS[@]}"; do [ "$id" != "$item" ] || known=1; done
    [ "$known" = 1 ] || die "Unknown component: $id"
    mac_select "$id"
  done < <(mac_selection_words "$1")
}
mac_load_nvm() {
  if [ -s "$NVM_DIR/nvm.sh" ]; then
    # shellcheck disable=SC1091
    . "$NVM_DIR/nvm.sh" --no-use
    nvm use --silent default >/dev/null 2>&1 || true
  fi
}
mac_find_brew() {
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
mac_tool() {
  local bin flag=--version
  bin="$(command -v "$1" || true)"
  [ -n "$bin" ] || return 1
  [ "$bin:$CLT_READY" != /usr/bin/git:0 ] || return 1
  [ "$1" != tmux ] || flag=-V
  "$bin" "$flag" >/dev/null 2>&1 || return 1
  printf '%s' "$bin"
}
mac_detect_tool() {
  local id="$1" bin flag=--version candidate
  DETECTED=missing; DETAIL='Not installed'
  # An existing Tailscale installation is never migrated or restarted.
  if [ "$id" = tailscale ]; then
    for candidate in /Applications/Tailscale.app "$HOME/Applications/Tailscale.app" \
      /Library/LaunchDaemons/homebrew.mxcl.tailscale.plist \
      /Library/LaunchDaemons/com.tailscale.tailscaled.plist \
      "$HOME/Library/LaunchAgents/homebrew.mxcl.tailscale.plist"; do
      if [ -e "$candidate" ] || [ -L "$candidate" ]; then DETECTED=installed; DETAIL="Present: $candidate (kept; no service/auth checks)"; return; fi
    done
    if command -v tailscaled >/dev/null 2>&1; then
      DETECTED=installed; DETAIL='tailscaled present (kept; no service/auth checks)'; return
    fi
  fi
  bin="$(command -v "$id" || true)"
  if [ "$id:$bin:$CLT_READY" = git:/usr/bin/git:0 ]; then
    DETAIL='Apple git placeholder; finish Command Line Tools'; return
  fi
  if [ -n "$bin" ]; then
    if mac_tool "$id" >/dev/null; then
      [ "$id" != tmux ] || flag=-V
      DETECTED=installed; DETAIL="$("$bin" "$flag" 2>&1 | head -n 1) [$bin]"
    else DETECTED=broken; DETAIL="Unusable: $bin; repair manually"; fi
    return
  fi
  for candidate in "$HOME/.local/bin/$id" "$HOME/.bun/bin/$id"; do
    if [ -e "$candidate" ] || [ -L "$candidate" ]; then DETECTED=broken; DETAIL="Unusable: $candidate; repair manually"; return; fi
  done
  if [ -n "$BREW_BIN" ] && [ "$BREW_BROKEN" = 0 ] && "$BREW_BIN" list --formula "$id" >/dev/null 2>&1; then
    if [ "$id" = tailscale ]; then DETECTED=installed; DETAIL='Homebrew formula present (kept, even if stopped)'
    else DETECTED=broken; DETAIL='Formula present but command unavailable; repair PATH manually'; fi
  fi
}
mac_shortcut_file() {
  local target="$1"
  if [ -f "$CONFIG_DIR/tmux.sh" ]; then cp "$CONFIG_DIR/tmux.sh" "$target"; fi
  ( TMUX_RC_FILE="$target"
    # shellcheck source=modules/80-tmux.sh
    . "$REPO_ROOT/modules/80-tmux.sh"
  ) >/dev/null
}
mac_config_state() {
  local id="$1" temp
  DETECTED=update; DETAIL='Needs configuration'
  if [ "$id" = shortcut ]; then
    if [ -L "$CONFIG_DIR/tmux.sh" ]; then DETECTED=broken; DETAIL='Symlink preserved; configure its target manually'; return; fi
    temp="$(mktemp)"
    mac_shortcut_file "$temp"
    if cmp -s "$temp" "$CONFIG_DIR/tmux.sh" && [ -d "$WORKSPACE_DIR" ]; then DETECTED=current; DETAIL='Configuration current'; fi
    rm -f "$temp"
  else
    CONFIG_CHECK=1; CONFIG_DIRTY=0; CONFIG_BLOCKED=0
    mac_shell_config
    CONFIG_CHECK=0
    if [ "$CONFIG_BLOCKED" = 1 ]; then DETECTED=broken; DETAIL='Symlinked profile needs manual integration'
    elif [ "$CONFIG_DIRTY" = 0 ]; then DETECTED=current; DETAIL='Configuration current'; fi
  fi
}
mac_discover() {
  local i=0 id
  CLT_READY=0; if xcode-select -p >/dev/null 2>&1; then CLT_READY=1; fi
  mac_find_brew
  export PATH="$HOME/.local/bin:$HOME/.bun/bin:$PATH"
  export NVM_DIR="${NVM_DIR:-$([ -z "${XDG_CONFIG_HOME:-}" ] && printf %s "$HOME/.nvm" || printf %s "$XDG_CONFIG_HOME/nvm")}"
  mac_load_nvm
  while [ "$i" -lt "${#COMPONENTS[@]}" ]; do
    id="${COMPONENTS[$i]}"
    case "$id" in shortcut|shell) mac_config_state "$id" ;; *) mac_detect_tool "$id" ;; esac
    STATES[$i]="$DETECTED"; DETAILS[$i]="$DETAIL"; RESULTS[$i]=''
    i=$((i+1))
  done
}
mac_eligible() { case "${STATES[$1]}" in missing|update) return 0 ;; *) return 1 ;; esac; }
mac_normalize() {
  local i=0 id
  mac_config_state shell
  STATES[10]="$DETECTED"; DETAILS[10]="$DETAIL"
  while [ "$i" -lt "${#COMPONENTS[@]}" ]; do
    if ! mac_eligible "$i"; then mac_deselect "${COMPONENTS[$i]}"; fi
    i=$((i+1))
  done
  if mac_selected shortcut; then
    case "${STATES[2]}" in missing) mac_select tmux ;; broken) mac_deselect shortcut; printf 'Shortcut skipped: repair existing tmux manually.\n' ;; esac
  fi
  # Selected tools can change PATH initialization; preview that configuration work.
  for id in tailscale mosh tmux git gh codex claude node bun shortcut; do
    if mac_selected "$id" && [ "${STATES[10]}" != broken ]; then
      STATES[10]=update; DETAILS[10]='Needs configuration for selected installation'
      mac_select shell
      break
    fi
  done
}
mac_inventory() {
  local i=0 mark
  printf '\nLocal installation inventory (not connectivity verification)\n'
  printf 'Homebrew dependency: %s\n' "${BREW_BIN:-not installed}"
  while [ "$i" -lt "${#COMPONENTS[@]}" ]; do
    [ "$i" != 0 ] || printf '\nTools\n'
    [ "$i" != 9 ] || printf '\nConfiguration\n'
    if mac_eligible "$i"; then
      mark=' '; if mac_selected "${COMPONENTS[$i]}"; then mark=x; fi
      printf ' %2s [%s] %-22s %s\n' "$((i+1))" "$mark" "${LABELS[$i]}" "${DETAILS[$i]}"
    else
      printf ' %2s LOCKED %-22s %s — %s\n' "$((i+1))" "${LABELS[$i]}" "${STATES[$i]}" "${DETAILS[$i]}"
    fi
    i=$((i+1))
  done
}
mac_plan() {
  local i=0 id
  NEED_BREW=0
  printf '\nPlan — selected eligible items only\n'
  while [ "$i" -lt "${#COMPONENTS[@]}" ]; do
    id="${COMPONENTS[$i]}"
    if mac_selected "$id"; then
      case "$id" in
        shortcut|shell) printf '  %s: configure/update (not software installation)\n' "$id" ;;
        *) printf '  %s: install missing tool\n' "$id" ;;
      esac
      case "$id" in tailscale|git|gh|tmux|mosh) NEED_BREW=1 ;; esac
    fi
    i=$((i+1))
  done
  if [ "$NEED_BREW" = 1 ]; then printf '  Homebrew dependency: %s\n' "${BREW_BIN:-install once}"; fi
  printf 'Existing tools and Tailscale services are kept. Power and Sharing are manual.\n'
}
mac_ensure_brew() {
  local installer
  [ "$BREW_BROKEN" = 0 ] || die 'Existing Homebrew is unusable; repair it manually'
  if [ -z "$BREW_BIN" ]; then
    installer="$(mktemp)"
    if ! curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh -o "$installer"; then rm -f "$installer"; return 1; fi
    if ! /bin/bash "$installer"; then rm -f "$installer"; return 1; fi
    rm -f "$installer"
    mac_find_brew
  fi
  [ -n "$BREW_BIN" ] && [ "$BREW_BROKEN" = 0 ]
}
mac_write() {
  local source="$1" target="$2" stage
  if cmp -s "$source" "$target"; then return 0; fi
  if [ "${CONFIG_CHECK:-0}" = 1 ]; then
    CONFIG_DIRTY=1
    [ ! -L "$target" ] || CONFIG_BLOCKED=1
    return 0
  fi
  if [ -L "$target" ]; then
    warn "Keeping symlink $target; apply the managed setup to its target manually."
    return 0
  fi
  if [ -f "$target" ] && [ ! -e "$target.vps-setup.bak" ]; then cp -p "$target" "$target.vps-setup.bak"; fi
  stage="$(mktemp "$target.tmp.XXXXXX")"
  if [ -f "$target" ]; then cp -p "$target" "$stage"; fi
  cat "$source" > "$stage"
  mv "$stage" "$target"
}
mac_backup_profiles() {
  local profile
  for profile in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile" \
    "$HOME/.bashrc" "$HOME/.zshrc" "${ZDOTDIR:-$HOME}/.zprofile" "${ZDOTDIR:-$HOME}/.zshrc"; do
    if [ -f "$profile" ] && [ ! -e "$profile.vps-setup.bak" ]; then
      cp -p "$profile" "$profile.vps-setup.bak"
    fi
  done
}
mac_shell_config() {
  local env_tmp profile_tmp env_file quoted brew_dir nvm_quote tmux_quote line profile bash_profile
  env_file="$CONFIG_DIR/env.sh"
  env_tmp="$(mktemp)"
  printf '%s\n' '# Managed by vps-setup/macOS.' > "$env_tmp"
  brew_dir=''
  if [ -n "$BREW_BIN" ]; then brew_dir="$(dirname "$BREW_BIN")"; fi
  for candidate in "$HOME/.local/bin" "$HOME/.bun/bin" "$brew_dir"; do
    [ -n "$candidate" ] || continue
    printf -v quoted '%q' "$candidate"
    printf 'case ":$PATH:" in *:%s:*) ;; *) export PATH=%s:"$PATH" ;; esac\n' "$quoted" "$quoted" >> "$env_tmp"
  done
  if [ -s "$NVM_DIR/nvm.sh" ]; then
    printf -v nvm_quote '%q' "$NVM_DIR"
    printf 'export NVM_DIR=%s\n[ ! -s "$NVM_DIR/nvm.sh" ] || . "$NVM_DIR/nvm.sh"\n' "$nvm_quote" >> "$env_tmp"
  fi
  if [ -f "$CONFIG_DIR/tmux.sh" ] || mac_selected shortcut; then
    printf -v tmux_quote '%q' "$CONFIG_DIR/tmux.sh"
    printf '[ ! -f %s ] || . %s\n' "$tmux_quote" "$tmux_quote" >> "$env_tmp"
  fi
  mac_write "$env_tmp" "$env_file"
  rm -f "$env_tmp"
  printf -v quoted '%q' "$env_file"
  line="[ ! -f $quoted ] || . $quoted # vps-setup:macos"
  bash_profile="$HOME/.bash_profile"
  for profile in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
    if [ -f "$profile" ]; then bash_profile="$profile"; break; fi
  done
  if [ "${CONFIG_CHECK:-0}" != 1 ]; then mkdir -p "${ZDOTDIR:-$HOME}"; fi
  for profile in "${ZDOTDIR:-$HOME}/.zprofile" "${ZDOTDIR:-$HOME}/.zshrc" "$bash_profile" "$HOME/.bashrc"; do
    profile_tmp="$(mktemp)"
    if [ -f "$profile" ]; then sed '/ # vps-setup:macos$/d' "$profile" > "$profile_tmp"; fi
    printf '%s\n' "$line" >> "$profile_tmp"
    mac_write "$profile_tmp" "$profile"
    rm -f "$profile_tmp"
  done
}

mac_manual() {
  printf '\nManual steps (not performed or tested):\n'
  printf '  • System Settings > General > Sharing: Remote Login / optional Screen Sharing; choose allowed users.\n'
  printf '  • System Settings > Energy: choose sleep and power-failure settings yourself.\n'
  printf '  • For a NEW Homebrew Tailscale install only, start it when ready: sudo brew services start tailscale.\n'
  printf '  • Sign in to Tailscale, GitHub and selected agents if needed; keep existing credentials.\n'
  printf '  • Open a new shell after configuration changes. tmux sessions do not survive reboots.\n'
}
mac_summary() {
  local i=0 result
  printf '\nSummary\n'
  while [ "$i" -lt "${#COMPONENTS[@]}" ]; do
    result="${RESULTS[$i]}"
    if [ -z "$result" ]; then
      case "${STATES[$i]}" in
        installed) result='Already present — kept' ;;
        current) result='Configuration current — kept' ;;
        broken) result='Manual repair needed — not changed' ;;
        *) result='Skipped' ;;
      esac
    fi
    printf '  %-22s %s\n' "${LABELS[$i]}" "$result"
    i=$((i+1))
  done
  mac_manual
}
