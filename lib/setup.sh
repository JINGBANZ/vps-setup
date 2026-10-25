#!/usr/bin/env bash
# Local server installation only; no authentication or client connection probes.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/onboarding.sh
. "$REPO_ROOT/lib/onboarding.sh"
case "$(uname -s)" in
  Darwin) PLATFORM=macos ;;
  Linux) PLATFORM=linux ;;
  *) die 'Supported hosts: Debian/Ubuntu Linux and macOS.' ;;
esac
# shellcheck source=/dev/null
. "$REPO_ROOT/$PLATFORM/platform.sh"
# shellcheck source=lib/terminal-ui.sh
. "$REPO_ROOT/lib/terminal-ui.sh"
# shellcheck source=lib/onboarding-ui.sh
. "$REPO_ROOT/lib/onboarding-ui.sh"
trap ui_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
SELECTED=' tailscale mosh tmux git gh codex claude shortcut shell '
platform_init
explicit=0; assume_yes=0; dry_run=0; check_only=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h) on_usage; exit 0 ;;
    --select) [ "$#" -ge 2 ] || die '--select requires a list'; on_parse_selection "$2"; explicit=1; shift ;;
    --yes) assume_yes=1 ;;
    --dry-run) dry_run=1 ;;
    --check) check_only=1 ;;
    *) die "Unknown argument: $1" ;;
  esac
  shift
done
[ "$assume_yes:$explicit" != 1:0 ] || die '--yes requires explicit --select'
# shellcheck source=lib/common.sh
. "$REPO_ROOT/lib/common.sh"
CONFIG_DIR="$HOME/.config/vps-setup"
case "$WORKSPACE_DIR" in /*) ;; *) die 'WORKSPACE_DIR must be absolute' ;; esac
case "${ZDOTDIR:-$HOME}" in /*) ;; *) die 'ZDOTDIR must be absolute' ;; esac
if [ "$explicit" = 0 ] && [ -f "$CONFIG_DIR/selection.txt" ]; then
  saved_current=''
  saved="$(cat "$CONFIG_DIR/selection.txt")"
  while IFS= read -r saved_id; do
    case "$saved_id" in
      ssh|screen|power) printf 'Retired saved choice %s: now manual.\n' "$saved_id" ;;
      *) saved_current="$saved_current $saved_id" ;;
    esac
  done < <(on_selection_words "$saved")
  on_parse_selection "${saved_current:-none}"
fi
if [ "$PLATFORM" = macos ] && [ "${MAC_TAILSCALE:-1}" = 0 ]; then on_deselect tailscale; fi
case "${VPS_SETUP_UI:-auto}" in auto) ;; *) die 'VPS_SETUP_UI only accepts auto; the numbered menu has been removed' ;; esac
on_discover
on_normalize
if [ "$check_only" = 1 ]; then on_inventory; exit 0; fi
if [ "$dry_run:$assume_yes" = 0:0 ]; then
  if [ -t 0 ]; then exec 3<&0
  elif ( : < /dev/tty ) 2>/dev/null; then exec 3</dev/tty
  else die 'A terminal is required; use --check, --dry-run or explicit --select LIST --yes'
  fi
  if [ -t 2 ]; then exec 4>&2
  elif [ -t 1 ]; then exec 4>&1
  else exec 4>/dev/tty; fi
  ui_prepare || die 'Cannot prepare Gum. Check TERM/network and retry, or use --check, --dry-run, or --select LIST --yes. No changes applied.'
  on_locked_inventory
  if [ "$explicit" = 0 ] && ! on_gum_menu; then
    printf 'Cancelled or menu interrupted; no changes applied.\n'; exit 0
  fi
else
  on_locked_inventory
fi
on_normalize
if [ "$SELECTED" = ' ' ]; then printf '\nNo changes selected.\n'; exit 0; fi
on_plan
if [ "$dry_run" = 1 ]; then exit 0; fi
if [ "$assume_yes" = 0 ]; then
  if ! ui_gum confirm 'Apply this plan?' --affirmative Apply --negative Cancel --default=false --timeout=0; then
    printf 'Cancelled; no changes applied.\n'; exit 0
  fi
fi
platform_preflight
if [ "$PLATFORM" = linux ]; then
  LOGFILE="${LOGFILE:-$HOME/vps-setup.log}"
  exec > >(tee -a "$LOGFILE") 2>&1
  log "Log: $LOGFILE"
fi
mkdir -p "$CONFIG_DIR"
failed=0
platform_prepare || die 'Platform dependencies or configuration failed; resolve the error and rerun'
# Install only items that were missing, rechecking before every mutation.
i=0
while [ "$i" -lt 9 ]; do
  item="${COMPONENTS[$i]}"
  if on_selected "$item"; then
    on_detect_tool "$item"
    if [ "$DETECTED" != missing ]; then
      if [ "$DETECTED" = installed ]; then RESULTS[$i]='Already installed'
      else RESULTS[$i]='Failed: existing installation needs repair'; failed=1; fi
    else
      success=0
      case "$item" in
        tailscale|git|gh|tmux|mosh)
          if platform_install_tool "$item"; then success=1; fi ;;
        node|bun|codex|claude)
          on_backup_profiles
          export INSTALL_NODE=0 INSTALL_BUN=0 INSTALL_CODEX=0 INSTALL_CLAUDE=0
          case "$item" in
            node) INSTALL_NODE=1 ;; bun) INSTALL_BUN=1 ;; codex) INSTALL_CODEX=1 ;; claude) INSTALL_CLAUDE=1 ;;
          esac
          export PROFILE=/dev/null BUN_INSTALL="$HOME/.bun"
          module=modules/70-agents.sh
          case "$item" in node|bun) module=modules/60-node-bun.sh ;; esac
          # A separate Bash process preserves errexit inside third-party modules.
          if /bin/bash -eo pipefail -c '. "$1/lib/common.sh"; . "$1/$2"' _ "$REPO_ROOT" "$module"; then success=1; fi
          on_load_nvm ;;
      esac
      hash -r
      if [ "$success" = 1 ] && on_tool "$item" >/dev/null; then
        RESULTS[$i]='Installed'
        # Even a new Tailscale installation leaves startup and sign-in manual.
      else RESULTS[$i]='Failed: check the installer output and retry'; failed=1; fi
    fi
  fi
  i=$((i+1))
done
if on_selected shortcut; then
  if on_tool tmux >/dev/null; then
    mkdir -p "$WORKSPACE_DIR"
    shortcut_tmp="$(mktemp)"
    on_shortcut_file "$shortcut_tmp"
    on_write "$shortcut_tmp" "$CONFIG_DIR/tmux.sh"
    rm -f "$shortcut_tmp"
    on_config_state shortcut
    if [ "$DETECTED" = current ]; then RESULTS[9]='Configured'
    else RESULTS[9]='Failed: shortcut configuration incomplete'; failed=1; fi
  else RESULTS[9]='Failed: tmux is unavailable'; failed=1; fi
fi
if on_selected shell; then
  on_shell_config
  on_config_state shell
  if [ "$DETECTED" = current ]; then RESULTS[10]='Configured'
  else RESULTS[10]='Failed: review shell configuration'; failed=1; fi
fi
platform_apply_extra || failed=1
if [ "$failed" = 0 ]; then
  selection_tmp="$(mktemp)"
  printf '%s\n' "$SELECTED" > "$selection_tmp"
  on_write "$selection_tmp" "$CONFIG_DIR/selection.txt"
  rm -f "$selection_tmp"
fi
on_summary
[ "$failed" = 0 ]
