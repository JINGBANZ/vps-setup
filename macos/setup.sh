#!/usr/bin/env bash
# Local server installation only; no authentication or client connection probes.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=macos/lib.sh
. "$REPO_ROOT/macos/lib.sh"
# shellcheck source=lib/terminal-ui.sh
. "$REPO_ROOT/lib/terminal-ui.sh"
# shellcheck source=macos/ui.sh
. "$REPO_ROOT/macos/ui.sh"
trap ui_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
SELECTED=' tailscale mosh tmux git gh codex claude shortcut shell '
DEFAULTS="$SELECTED"
explicit=0; assume_yes=0; dry_run=0; check_only=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h) mac_usage; exit 0 ;;
    --select) [ "$#" -ge 2 ] || die '--select requires a list'; mac_parse_selection "$2"; explicit=1; shift ;;
    --yes) assume_yes=1 ;;
    --dry-run) dry_run=1 ;;
    --check) check_only=1 ;;
    *) die "Unknown argument: $1" ;;
  esac
  shift
done
[ "$assume_yes:$explicit" != 1:0 ] || die '--yes requires explicit --select'
[ "$(uname -s)" = Darwin ] || die 'macOS required'
[ "$(id -u)" -ne 0 ] || die 'Run without sudo as your normal administrator user'
[ -z "${GH_RUNNER_REPO:-}" ] && [ "${DEV_POSTGRES:-0}" = 0 ] || die 'PostgreSQL and Actions runner are Linux-only'
# shellcheck source=lib/common.sh
. "$REPO_ROOT/lib/common.sh"
CONFIG_DIR="$HOME/.config/vps-setup"
case "$WORKSPACE_DIR" in /*) ;; *) die 'WORKSPACE_DIR must be absolute' ;; esac
case "${ZDOTDIR:-$HOME}" in /*) ;; *) die 'ZDOTDIR must be absolute' ;; esac
case "${MAC_TAILSCALE:-1}" in 0|1) ;; *) die 'MAC_TAILSCALE must be 0 or 1' ;; esac
if [ "$explicit" = 0 ] && [ -f "$CONFIG_DIR/selection.txt" ]; then
  saved_current=''
  saved="$(cat "$CONFIG_DIR/selection.txt")"
  while IFS= read -r saved_id; do
    case "$saved_id" in
      ssh|screen|power) printf 'Retired saved choice %s: now manual.\n' "$saved_id" ;;
      *) saved_current="$saved_current $saved_id" ;;
    esac
  done < <(mac_selection_words "$saved")
  mac_parse_selection "${saved_current:-none}"
fi
[ "${MAC_TAILSCALE:-1}" = 1 ] || mac_deselect tailscale
case "${VPS_SETUP_UI:-auto}" in auto|plain) ;; *) die 'VPS_SETUP_UI must be auto or plain' ;; esac
mac_discover
mac_normalize
UI_MODE=plain
if [ "$check_only" = 1 ]; then mac_inventory; mac_manual; exit 0; fi
if [ "$dry_run:$assume_yes" = 0:0 ]; then
  if [ -t 0 ]; then exec 3<&0
  elif ( : < /dev/tty ) 2>/dev/null; then exec 3</dev/tty
  else die 'A terminal is required; use --check, --dry-run or explicit --select LIST --yes'
  fi
  if [ -t 2 ]; then exec 4>&2
  elif [ -t 1 ]; then exec 4>&1
  else exec 4>/dev/tty; fi
  if ui_prepare; then
    UI_MODE=gum
    mac_locked_inventory
    if [ "$explicit" = 0 ] && ! mac_gum_menu; then
      printf 'Cancelled or menu interrupted; no changes applied.\n'; exit 0
    fi
  else
    mac_inventory
    if [ "$explicit" = 0 ] && ! mac_plain_menu; then exit 0; fi
  fi
else
  mac_inventory
fi
mac_normalize
mac_plan
if [ "$dry_run" = 1 ]; then mac_manual; exit 0; fi
if [ "$assume_yes" = 0 ]; then
  if [ "$UI_MODE" = gum ]; then
    if ! ui_gum confirm 'Apply this plan?' --affirmative Install --negative Cancel --default=false --timeout=0; then
      printf 'Cancelled; no changes applied.\n'; exit 0
    fi
  else
    printf 'Type apply to continue, or anything else to cancel: '
    IFS= read -r answer <&3 || die 'Input ended; no changes applied'
    [ "$answer" = apply ] || { printf 'Cancelled; no changes applied.\n'; exit 0; }
  fi
fi
if [ "$SELECTED" = ' ' ]; then printf 'No eligible items selected; no changes applied.\n'; mac_summary; exit 0; fi
if [ "$NEED_BREW" = 1 ]; then
  [ "$CLT_READY" = 1 ] || die 'Finish xcode-select --install first; no changes applied'
  [ "$BREW_BROKEN" = 0 ] || die 'Repair existing Homebrew first; no changes applied'
fi
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_UPGRADE=1
mkdir -p "$CONFIG_DIR"
failed=0; brew_ready=1
if [ "$NEED_BREW" = 1 ] && ! mac_ensure_brew; then brew_ready=0; failed=1; warn 'Homebrew dependency failed'; fi
# Install only items that were missing, rechecking before every mutation.
i=0
while [ "$i" -lt 9 ]; do
  item="${COMPONENTS[$i]}"
  if mac_selected "$item"; then
    mac_detect_tool "$item"
    if [ "$DETECTED" != missing ]; then
      if [ "$DETECTED" = installed ]; then RESULTS[$i]='Already present — kept'
      else RESULTS[$i]='Failed — detected existing unusable installation; repair manually'; failed=1; fi
    else
      success=0
      case "$item" in
        tailscale|git|gh|tmux|mosh)
          if [ "$brew_ready" = 1 ] && "$BREW_BIN" install --formula "$item"; then success=1; fi ;;
        node|bun|codex|claude)
          mac_backup_profiles
          export INSTALL_NODE=0 INSTALL_BUN=0 INSTALL_CODEX=0 INSTALL_CLAUDE=0
          case "$item" in
            node) INSTALL_NODE=1 ;; bun) INSTALL_BUN=1 ;; codex) INSTALL_CODEX=1 ;; claude) INSTALL_CLAUDE=1 ;;
          esac
          export PROFILE=/dev/null BUN_INSTALL="$HOME/.bun"
          module=modules/70-agents.sh
          case "$item" in node|bun) module=modules/60-node-bun.sh ;; esac
          # A separate Bash process preserves errexit inside third-party modules.
          if /bin/bash -eo pipefail -c '. "$1/lib/common.sh"; . "$1/$2"' _ "$REPO_ROOT" "$module"; then success=1; fi
          mac_load_nvm ;;
      esac
      hash -r
      if [ "$success" = 1 ] && mac_tool "$item" >/dev/null; then
        RESULTS[$i]='Installed — local version checked'
        # Even a new Tailscale installation leaves startup and sign-in manual.
      else RESULTS[$i]='Failed — installation incomplete; rerun after resolving the error'; failed=1; fi
    fi
  fi
  i=$((i+1))
done
if mac_selected shortcut; then
  if mac_tool tmux >/dev/null; then
    mkdir -p "$WORKSPACE_DIR"
    shortcut_tmp="$(mktemp)"
    mac_shortcut_file "$shortcut_tmp"
    mac_write "$shortcut_tmp" "$CONFIG_DIR/tmux.sh"
    rm -f "$shortcut_tmp"
    mac_config_state shortcut
    if [ "$DETECTED" = current ]; then RESULTS[9]='Configured — local content checked'
    else RESULTS[9]='Failed — shortcut configuration incomplete'; failed=1; fi
  else RESULTS[9]='Failed — tmux dependency unavailable'; failed=1; fi
fi
if mac_selected shell; then
  mac_shell_config
  mac_config_state shell
  if [ "$DETECTED" = current ]; then RESULTS[10]='Configured — local content checked'
  else RESULTS[10]='Failed — shell integration needs manual review'; failed=1; fi
fi
if [ "$failed" = 0 ]; then
  selection_tmp="$(mktemp)"
  printf '%s\n' "$SELECTED" > "$selection_tmp"
  mac_write "$selection_tmp" "$CONFIG_DIR/selection.txt"
  rm -f "$selection_tmp"
fi
mac_summary
[ "$failed" = 0 ]
