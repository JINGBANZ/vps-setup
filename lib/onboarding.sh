#!/usr/bin/env bash
# Shared inventory, selection and configuration; compatible with Apple Bash 3.2.
COMPONENTS=(tailscale mosh tmux git gh codex claude node bun shortcut shell)
LABELS=('Tailscale' 'Mosh' 'tmux' 'Git' 'GitHub CLI' 'Codex' 'Claude Code' 'Node.js / nvm' 'Bun' 'Session shortcut: t' 'Shell integration')
STATES=(); DETAILS=(); RESULTS=()
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
on_usage() {
  cat <<'EOF'
Usage: bash setup.sh [options] (normal user; Linux requests sudo as needed)
  --check             Show installed versions, paths and repair details.
  --dry-run           Read-only plan; no installation or connection probes.
  --select LIST       Comma-separated IDs, or none. Installed items stay locked.
  --yes               Apply an explicit --select list without menu confirmation.
  --help              Show help.
Interactive: arrows move, Space toggles, Enter continues; review Apply / Cancel.
Interactive setup requires Gum (automatically bootstrapped; no numbered menu).
Tools: tailscale,mosh,tmux,git,gh,codex,claude,node,bun
Configuration: shortcut,shell
Linux only: security,disk-guard,runner,postgres,tailscale-hardening
Node and Bun default off. Only missing tools and outdated configuration are selectable.
Interactive setup offers optional GitHub HTTPS sign-in after successful changes.
--yes skips sign-in. On macOS, SSH, Screen Sharing and power remain manual.
EOF
}
on_selected() { case "$SELECTED" in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
on_select() { if ! on_selected "$1"; then SELECTED="$SELECTED$1 "; fi; }
on_deselect() { SELECTED="${SELECTED// $1 / }"; }
on_selection_words() (
  # Split plain selection data without expanding patterns. Keep noglob inside
  # this subshell: nvm needs normal filename expansion to discover versions.
  set -f
  for word in ${1//,/ }; do printf '%s\n' "$word"; done
)
on_parse_selection() {
  local id item known
  SELECTED=' '
  [ "$1" != none ] || return 0
  [ -n "$1" ] || die 'Empty selection; use none'
  while IFS= read -r id; do
    case "$id" in ssh|screen|power) die "$id is manual; remove it from --select" ;; esac
    known=0
    for item in "${COMPONENTS[@]}"; do [ "$id" != "$item" ] || known=1; done
    [ "$known" = 1 ] || die "Unknown component: $id"
    on_select "$id"
  done < <(on_selection_words "$1")
}
on_load_nvm() {
  if [ -s "$NVM_DIR/nvm.sh" ]; then
    # shellcheck disable=SC1091
    . "$NVM_DIR/nvm.sh" --no-use
    nvm use --silent default >/dev/null 2>&1 || true
  fi
}
on_tool() {
  local bin flag=--version
  bin="$(command -v "$1" || true)"
  [ -n "$bin" ] || return 1
  [ "$bin:$CLT_READY" != /usr/bin/git:0 ] || return 1
  [ "$1" != tmux ] || flag=-V
  "$bin" "$flag" >/dev/null 2>&1 || return 1
  printf '%s' "$bin"
}
on_detect_tool() {
  local id="$1" bin flag=--version candidate
  DETECTED=missing; DETAIL='Not installed'
  if platform_detect_tool "$id"; then return; fi
  if [ "$id" = tailscale ] && command -v tailscaled >/dev/null 2>&1; then
    DETECTED=installed; DETAIL='tailscaled present (kept; no service/auth checks)'; return
  fi
  bin="$(command -v "$id" || true)"
  if [ "$id:$bin:$CLT_READY" = git:/usr/bin/git:0 ]; then
    DETAIL='Apple git placeholder; finish Command Line Tools'; return
  fi
  if [ -n "$bin" ]; then
    if on_tool "$id" >/dev/null; then
      [ "$id" != tmux ] || flag=-V
      DETECTED=installed; DETAIL="$("$bin" "$flag" 2>&1 | head -n 1) [$bin]"
    else DETECTED=broken; DETAIL="Unusable: $bin; repair manually"; fi
    return
  fi
  for candidate in "$HOME/.local/bin/$id" "$HOME/.bun/bin/$id"; do
    if [ -e "$candidate" ] || [ -L "$candidate" ]; then DETECTED=broken; DETAIL="Unusable: $candidate; repair manually"; return; fi
  done
  platform_detect_package "$id"
}
on_shortcut_file() {
  local target="$1"
  if [ -f "$CONFIG_DIR/tmux.sh" ]; then cp "$CONFIG_DIR/tmux.sh" "$target"; fi
  ( TMUX_RC_FILE="$target"
    # shellcheck source=modules/80-tmux.sh
    . "$REPO_ROOT/modules/80-tmux.sh"
  ) >/dev/null
}
on_config_state() {
  local id="$1" temp
  DETECTED=update; DETAIL='Needs configuration'
  if [ "$id" = shortcut ]; then
    if [ -L "$CONFIG_DIR/tmux.sh" ]; then DETECTED=broken; DETAIL='Symlink preserved; configure its target manually'; return; fi
    temp="$(mktemp)"
    on_shortcut_file "$temp"
    if cmp -s "$temp" "$CONFIG_DIR/tmux.sh" && [ -d "$WORKSPACE_DIR" ]; then DETECTED=current; DETAIL='Configuration current'; fi
    rm -f "$temp"
  else
    CONFIG_CHECK=1; CONFIG_DIRTY=0; CONFIG_BLOCKED=0
    on_shell_config
    CONFIG_CHECK=0
    if [ "$CONFIG_BLOCKED" = 1 ]; then DETECTED=broken; DETAIL='Symlinked profile needs manual integration'
    elif [ "$CONFIG_DIRTY" = 0 ]; then DETECTED=current; DETAIL='Configuration current'; fi
  fi
}
on_discover() {
  local i=0 id
  platform_discover
  export PATH="$HOME/.local/bin:$HOME/.bun/bin:$PATH"
  export NVM_DIR="${NVM_DIR:-$([ -z "${XDG_CONFIG_HOME:-}" ] && printf %s "$HOME/.nvm" || printf %s "$XDG_CONFIG_HOME/nvm")}"
  on_load_nvm
  while [ "$i" -lt "${#COMPONENTS[@]}" ]; do
    id="${COMPONENTS[$i]}"
    case "$id" in
      shortcut|shell) on_config_state "$id" ;;
      security|disk-guard|runner|postgres|tailscale-hardening) platform_detect_extra "$id" ;;
      *) on_detect_tool "$id" ;;
    esac
    STATES[$i]="$DETECTED"; DETAILS[$i]="$DETAIL"; RESULTS[$i]=''
    i=$((i+1))
  done
}
on_eligible() { case "${STATES[$1]}" in missing|update) return 0 ;; *) return 1 ;; esac; }
on_normalize() {
  local i=0 id
  on_config_state shell
  STATES[10]="$DETECTED"; DETAILS[10]="$DETAIL"
  while [ "$i" -lt "${#COMPONENTS[@]}" ]; do
    if ! on_eligible "$i"; then on_deselect "${COMPONENTS[$i]}"; fi
    i=$((i+1))
  done
  if on_selected shortcut; then
    case "${STATES[2]}" in missing) on_select tmux ;; broken) on_deselect shortcut; printf 'Shortcut skipped: repair existing tmux manually.\n' ;; esac
  fi
  # Selected tools can change PATH initialization; preview that configuration work.
  for id in tailscale mosh tmux git gh codex claude node bun shortcut; do
    if on_selected "$id" && [ "${STATES[10]}" != broken ]; then
      STATES[10]=update; DETAILS[10]='Needs configuration for selected installation'
      on_select shell
      break
    fi
  done
}
on_inventory() {
  local i=0 mark
  printf '\nInventory\n'
  platform_inventory
  while [ "$i" -lt "${#COMPONENTS[@]}" ]; do
    [ "$i" != 0 ] || printf '\nTools\n'
    [ "$i" != 9 ] || printf '\nConfiguration\n'
    if on_eligible "$i"; then
      mark=' '; if on_selected "${COMPONENTS[$i]}"; then mark=x; fi
      printf ' [%s] %-22s %s\n' "$mark" "${LABELS[$i]}" "${DETAILS[$i]}"
    else
      printf ' LOCKED %-22s %s — %s\n' "${LABELS[$i]}" "${STATES[$i]}" "${DETAILS[$i]}"
    fi
    i=$((i+1))
  done
}
on_plan() {
  local i=0 id
  printf '\nPlan\n'
  platform_plan
  while [ "$i" -lt "${#COMPONENTS[@]}" ]; do
    id="${COMPONENTS[$i]}"
    if on_selected "$id"; then
      case "$id" in
        shell) printf '  - Configure shell PATH and startup\n' ;;
        shortcut)
          printf '  - Set up t shortcut\n'
          if [ "$WORKSPACE_DIR" != "$HOME/workspace" ]; then printf '    Sessions: %s\n' "$WORKSPACE_DIR"; fi ;;
        security|disk-guard|runner|postgres|tailscale-hardening) platform_plan_component "$id" ;;
        *) printf '  - Install %s\n' "${LABELS[$i]}" ;;
      esac
    fi
    i=$((i+1))
  done
}

on_write() {
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
on_backup_profiles() {
  local profile
  for profile in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile" \
    "$HOME/.bashrc" "$HOME/.zshrc" "${ZDOTDIR:-$HOME}/.zprofile" "${ZDOTDIR:-$HOME}/.zshrc"; do
    if [ -f "$profile" ] && [ ! -e "$profile.vps-setup.bak" ]; then
      cp -p "$profile" "$profile.vps-setup.bak"
    fi
  done
}
on_shell_config() {
  local env_tmp path_tmp profile_tmp env_file path_file quoted nvm_quote tmux_quote line profile bash_profile
  env_file="$CONFIG_DIR/env.sh"
  path_file="$CONFIG_DIR/path.sh"
  env_tmp="$(mktemp)"
  path_tmp="$(mktemp)"
  printf '%s\n' '# Managed by vps-setup.' > "$env_tmp"
  printf '%s\n' '# Managed by vps-setup. Silent environment setup.' > "$path_tmp"
  if [ -n "$BREW_BIN" ]; then
    printf -v quoted '%q' "$BREW_BIN"
    printf '_vps_setup_brew=%s\n' "$quoted" >> "$path_tmp"
    cat "$REPO_ROOT/lib/shell-brew.sh" >> "$path_tmp"
  fi
  for candidate in "$HOME/.local/bin" "$HOME/.bun/bin"; do
    [ -n "$candidate" ] || continue
    printf -v quoted '%q' "$candidate"
    printf 'case ":$PATH:" in *:%s:*) ;; *) export PATH=%s:"$PATH" ;; esac\n' "$quoted" "$quoted" >> "$path_tmp"
  done
  on_write "$path_tmp" "$path_file"
  rm -f "$path_tmp"
  printf -v quoted '%q' "$path_file"
  printf '[ ! -f %s ] || . %s\n' "$quoted" "$quoted" >> "$env_tmp"
  if [ -s "$NVM_DIR/nvm.sh" ]; then
    printf -v nvm_quote '%q' "$NVM_DIR"
    # Use nvm's own activation logic so Node also works in executable scripts
    # (not just shell functions), and inherited version selections are honored.
    printf 'export NVM_DIR=%s\n' "$nvm_quote" >> "$env_tmp"
    cat >> "$env_tmp" <<'EOF'
if ! typeset -f nvm >/dev/null 2>&1 && [ -s "$NVM_DIR/nvm.sh" ]; then
  # A zero-argument function prevents job arguments (such as --install) from
  # becoming nvm.sh options when this file is loaded through BASH_ENV.
  _vps_setup_load_nvm() { . "$NVM_DIR/nvm.sh" >/dev/null; }
  _vps_setup_load_nvm
  unset -f _vps_setup_load_nvm
fi
# macOS path_helper can reorder PATH between .zshenv and .zprofile. Restore
# the active nvm bin without reloading nvm, changing versions or duplicating it.
if [ -n "${NVM_BIN:-}" ] && [ -x "$NVM_BIN/node" ] &&
   [ "$(command -v node)" != "$NVM_BIN/node" ]; then
  _vps_setup_path_rest="${PATH:-}"
  _vps_setup_path_tail=''
  while :; do
    _vps_setup_path_part="${_vps_setup_path_rest%%:*}"
    if [ "$_vps_setup_path_part" != "$NVM_BIN" ]; then
      _vps_setup_path_tail="$_vps_setup_path_tail:$_vps_setup_path_part"
    fi
    case "$_vps_setup_path_rest" in
      *:*) _vps_setup_path_rest="${_vps_setup_path_rest#*:}" ;;
      *) break ;;
    esac
  done
  export PATH="$NVM_BIN$_vps_setup_path_tail"
  unset _vps_setup_path_rest _vps_setup_path_tail _vps_setup_path_part
fi
EOF
  fi
  if [ -f "$CONFIG_DIR/tmux.sh" ] || on_selected shortcut; then
    printf -v tmux_quote '%q' "$CONFIG_DIR/tmux.sh"
    printf '[ ! -f %s ] || . %s\n' "$tmux_quote" "$tmux_quote" >> "$env_tmp"
  fi
  on_write "$env_tmp" "$env_file"
  rm -f "$env_tmp"
  printf -v quoted '%q' "$env_file"
  line="[ ! -f $quoted ] || . $quoted # vps-setup:shell"
  bash_profile="$HOME/.bash_profile"
  for profile in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
    if [ -f "$profile" ]; then bash_profile="$profile"; break; fi
  done
  if [ "${CONFIG_CHECK:-0}" != 1 ]; then mkdir -p "${ZDOTDIR:-$HOME}"; fi
  for profile in "${ZDOTDIR:-$HOME}/.zshenv" "${ZDOTDIR:-$HOME}/.zprofile" "${ZDOTDIR:-$HOME}/.zshrc" "$bash_profile" "$HOME/.bashrc"; do
    profile_tmp="$(mktemp)"
    # Remote Bash reads .bashrc, whose existing non-interactive guard can return
    # early. The shared environment must precede it; retain all custom content.
    if [ "$profile" = "$HOME/.bashrc" ]; then printf '%s\n' "$line" > "$profile_tmp"; fi
    if [ -f "$profile" ]; then sed '/ # vps-setup:macos$/d; / # vps-setup:shell$/d; / # vps-setup:path$/d' "$profile" >> "$profile_tmp"; fi
    if [ "$profile" != "$HOME/.bashrc" ]; then
      printf '%s\n' "$line" >> "$profile_tmp"
    fi
    on_write "$profile_tmp" "$profile"
    rm -f "$profile_tmp"
  done
}

on_next_step() {
  if [ "$NEXT_STEPS_SHOWN" = 0 ]; then printf '\nNext\n'; NEXT_STEPS_SHOWN=1; fi
  printf '  - %s\n' "$1"
}
on_summary() {
  local i=0 result label
  printf '\nResults\n'
  while [ "$i" -lt "${#COMPONENTS[@]}" ]; do
    result="${RESULTS[$i]}"
    label="${LABELS[$i]}"
    [ "${COMPONENTS[$i]}" != shortcut ] || label='t shortcut'
    if [ -n "$result" ]; then printf '  - %s: %s\n' "$label" "$result"; fi
    i=$((i+1))
  done
  NEXT_STEPS_SHOWN=0
  if [ "${RESULTS[10]}" = Configured ]; then on_next_step 'Open a new terminal or SSH session to load shell changes.'; fi
  if [ "${RESULTS[9]}" = Configured ]; then on_next_step 'Start or resume a session: t <name>'; fi
  if [ "${RESULTS[4]}" = Installed ]; then on_next_step 'GitHub sign-in and recovery: https://github.com/JINGBANZ/vps-setup#github-authentication'; fi
  if [ "${RESULTS[5]}" = Installed ]; then on_next_step 'Codex sign-in, if needed: codex'; fi
  if [ "${RESULTS[6]}" = Installed ]; then on_next_step 'Claude Code sign-in, if needed: claude'; fi
  platform_next_steps
}

