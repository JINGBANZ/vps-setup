#!/usr/bin/env bash
# Interactive Mac provisioning; compatible with Apple's Bash 3.2.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=macos/lib.sh
. "$REPO_ROOT/macos/lib.sh"
SELECTED=" tailscale ssh mosh tmux shortcut git gh codex claude screen "
DEFAULTS="$SELECTED"
explicit=0; assume_yes=0; dry_run=0; check_only=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h) mac_usage; exit 0 ;;
    --select)
      [ "$#" -ge 2 ] || die '--select requires a list (or none)'
      mac_parse_selection "$2"; explicit=1; shift ;;
    --yes) assume_yes=1 ;;
    --dry-run) dry_run=1 ;;
    --check) check_only=1 ;;
    *) die "Unknown argument: $1 (see --help)" ;;
  esac
  shift
done
[ "$assume_yes:$explicit" != 1:0 ] || die '--yes requires an explicit --select list'
[ "$(uname -s)" = Darwin ] || die 'macos/setup.sh requires macOS'
[ "$(id -u)" -ne 0 ] || die 'Run bash setup.sh as your normal user WITHOUT sudo'
[ -z "${GH_RUNNER_REPO:-}" ] && [ "${DEV_POSTGRES:-0}" = 0 ] || die 'PostgreSQL and GitHub Actions runner are Linux-only'
# shellcheck source=lib/common.sh
. "$REPO_ROOT/lib/common.sh"
CONFIG_DIR="$HOME/.config/vps-setup"
case "$WORKSPACE_DIR" in /*) ;; *) die 'WORKSPACE_DIR must be an absolute path' ;; esac
case "${ZDOTDIR:-$HOME}" in /*) ;; *) die 'ZDOTDIR must be an absolute path' ;; esac
case "${MAC_TAILSCALE:-1}" in
  0|1) ;; *) die 'MAC_TAILSCALE must be 0 or 1' ;;
esac
# Plain validated data, never sourced as executable code.
if [ "$explicit" = 0 ] && [ -f "$CONFIG_DIR/selection.txt" ]; then
  saved="$(cat "$CONFIG_DIR/selection.txt")"
  # Retire only the former power choice; still reject other invalid saved IDs.
  saved_current=''
  for saved_id in ${saved//,/ }; do
    if [ "$saved_id" = power ]; then
      printf 'Ignoring saved power choice; configure power manually in System Settings.\n'
    else
      saved_current="$saved_current $saved_id"
    fi
  done
  mac_parse_selection "${saved_current:-none}"
fi
[ "${MAC_TAILSCALE:-1}" = 1 ] || mac_deselect tailscale
mac_discover
mac_inventory
if [ "$check_only" = 1 ]; then mac_addresses; exit 0; fi
if [ "$dry_run" = 0 ] && [ "$assume_yes" = 0 ]; then
  if [ -t 0 ]; then exec 3<&0
  elif ( : < /dev/tty ) 2>/dev/null; then exec 3</dev/tty
  else die 'A terminal is required. Use --select LIST --yes for automation, or --check / --dry-run to inspect.'
  fi
  if [ "$explicit" = 0 ]; then
    while :; do
      mac_menu
      printf 'Toggle numbers (e.g. 3,4), all / none / defaults, Enter to review, q to quit: '
      IFS= read -r answer <&3 || die 'Input ended; no changes applied'
      case "$answer" in
        '') break ;;
        q|quit) exit 0 ;;
        all) SELECTED=" ${COMPONENTS[*]} " ;;
        none) SELECTED=' ' ;;
        defaults) SELECTED="$DEFAULTS" ;;
        *)
          for token in ${answer//,/ }; do
            case "$token" in
              1|2|3|4|5|6|7|8|9|10|11|12)
                item="${COMPONENTS[$((token-1))]}"
                if mac_selected "$item"; then mac_deselect "$item"; else mac_select "$item"; fi ;;
              *) printf 'Unknown selection: %s\n' "$token" ;;
            esac
          done ;;
      esac
    done
  fi
fi
if mac_selected shortcut && ! mac_selected tmux; then
  mac_select tmux; printf '\nDependency added: tmux for the t shortcut.\n'
fi
if mac_selected mosh && ! mac_selected ssh; then
  mac_select ssh; printf '\nDependency added: Remote Login guidance for Mosh.\n'
fi
mac_plan
[ "$dry_run" = 0 ] || exit 0
if [ "$assume_yes" = 0 ]; then
  printf '\nType apply to continue, or anything else to cancel: '
  IFS= read -r answer <&3 || die 'Input ended; no changes applied'
  [ "$answer" = apply ] || { printf 'Cancelled; no changes applied.\n'; exit 0; }
fi
[ "$SELECTED" != ' ' ] || { printf 'Nothing selected; no changes applied.\n'; exit 0; }
if mac_selected tailscale && [ "$TS_KIND" = conflict ]; then
  die 'Conflicting Tailscale installations. Resolve locally or deselect tailscale; no changes applied.'
fi
if [ "$NEED_BREW" = 1 ] && [ "$CLT_READY" = 0 ]; then
  die 'Run xcode-select --install, finish the Apple installer, then rerun. No changes applied.'
fi
# Mutations start here. Package/agent installers run as the normal user.
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_UPGRADE=1
mkdir -p "$CONFIG_DIR"
if [ "$NEED_BREW" = 1 ]; then mac_ensure_brew; fi
for component in git gh tmux mosh; do
  if mac_selected "$component" && ! mac_tool "$component" >/dev/null; then
    "$BREW_BIN" install --formula "$component"
    mac_tool "$component" >/dev/null || die "$component unavailable; fix PATH and rerun"
  fi
done
if mac_selected tailscale; then mac_tailscale; fi
# Independent native installers; Linux defaults remain enabled.
INSTALL_NODE=0; INSTALL_BUN=0; INSTALL_CODEX=0; INSTALL_CLAUDE=0
if mac_selected node && ! mac_tool node >/dev/null; then INSTALL_NODE=1; fi
if mac_selected bun && ! mac_tool bun >/dev/null; then INSTALL_BUN=1; fi
if mac_selected codex && ! mac_tool codex >/dev/null; then INSTALL_CODEX=1; fi
if mac_selected claude && ! mac_tool claude >/dev/null; then INSTALL_CLAUDE=1; fi
export PROFILE=/dev/null BUN_INSTALL="$HOME/.bun"
# Preserve original startup files only when a native installer will run.
if [ "$INSTALL_NODE$INSTALL_BUN$INSTALL_CODEX$INSTALL_CLAUDE" != 0000 ]; then mac_backup_profiles; fi
# shellcheck source=modules/60-node-bun.sh
. "$REPO_ROOT/modules/60-node-bun.sh"
# shellcheck source=modules/70-agents.sh
. "$REPO_ROOT/modules/70-agents.sh"
if mac_selected shortcut; then
  mkdir -p "$WORKSPACE_DIR"
  shortcut_tmp="$(mktemp)"
  if [ -f "$CONFIG_DIR/tmux.sh" ]; then cp "$CONFIG_DIR/tmux.sh" "$shortcut_tmp"; fi
  TMUX_RC_FILE="$shortcut_tmp"
  # shellcheck source=modules/80-tmux.sh
  . "$REPO_ROOT/modules/80-tmux.sh"
  mac_write "$shortcut_tmp" "$CONFIG_DIR/tmux.sh"
  rm -f "$shortcut_tmp"
fi
mac_shell_config
missing=0
for component in git gh tmux mosh node bun codex claude; do
  if mac_selected "$component" && ! mac_tool "$component" >/dev/null; then
    warn "$component unavailable; rerun to retry"; missing=1
  fi
done
if [ "$missing" = 0 ]; then
  selection_tmp="$(mktemp)"
  printf '%s\n' "$SELECTED" > "$selection_tmp"
  mac_write "$selection_tmp" "$CONFIG_DIR/selection.txt"
  rm -f "$selection_tmp"
fi
mac_finish
[ "$missing" = 0 ] || exit 1
