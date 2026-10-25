#!/usr/bin/env bash
# Presentation only. Selection/dependency validation stays in macos/lib.sh.
mac_locked_inventory() {
  local i=0
  printf '\nAlready present / manual repair (read-only)\n'
  while [ "$i" -lt "${#COMPONENTS[@]}" ]; do
    if ! mac_eligible "$i"; then
      printf '  %-22s %s — %s\n' "${LABELS[$i]}" "${STATES[$i]}" "${DETAILS[$i]}"
    fi
    i=$((i+1))
  done
}

mac_gum_pick() {
  local i="$1" end="$2" title="$3" id defaults='' offered=' ' output
  local options=()
  while [ "$i" -lt "$end" ]; do
    id="${COMPONENTS[$i]}"
    if mac_eligible "$i" && [ "$id:$SHELL_REQUIRED" != shell:1 ]; then
      options[${#options[@]}]="${LABELS[$i]}|$id"
      offered="$offered$id "
      if mac_selected "$id"; then defaults="${defaults:+$defaults,}${LABELS[$i]}"; fi
    fi
    i=$((i+1))
  done
  [ "${#options[@]}" -gt 0 ] || return 0
  printf '\n%s\n↑/↓ move • Space toggle • Ctrl-A all/none • Enter continue • Esc cancel\n' "$title" >&4
  if ! output="$(ui_gum choose --no-limit --height 11 --header "$title" \
    --selected="$defaults" --selected-prefix '[x] ' --cursor-prefix '[ ] ' \
    --unselected-prefix '[ ] ' --label-delimiter '|' --output-delimiter $'\n' \
    --timeout=0 --ordered=false "${options[@]}")"; then return 1; fi
  # A successful empty result means select none, not cancellation.
  while IFS= read -r id; do mac_deselect "$id"; done < <(mac_selection_words "$offered")
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    case "$offered" in *" $id "*) mac_select "$id" ;; *) return 1 ;; esac
  done <<< "$output"
}

mac_gum_menu() {
  local id
  SHELL_REQUIRED=0
  mac_gum_pick 0 9 '1/2 · Choose tools to install' || return 1
  # Wait until both pages are complete before adding shortcut dependencies.
  # Otherwise a default shortcut can reselect tmux even when both are later off.
  mac_config_state shell
  STATES[10]="$DETECTED"; DETAILS[10]="$DETAIL"
  # Required shell integration is displayed as a dependency, not a checkbox.
  for id in tailscale mosh tmux git gh codex claude node bun; do
    if mac_selected "$id" && [ "${STATES[10]}" != broken ]; then SHELL_REQUIRED=1; break; fi
  done
  if [ "$SHELL_REQUIRED" = 1 ]; then
    STATES[10]=update; DETAILS[10]='Needs configuration for selected installation'
    mac_select shell
    printf '\nShell integration: required for selected tools.\n' >&4
  fi
  mac_gum_pick 9 11 '2/2 · Choose configuration updates' || return 1
  mac_normalize
}

# SELECTED is shared with mac_normalize/mac_selected in macos/lib.sh.
# shellcheck disable=SC2034
mac_plain_menu() {
  local answer token index item
  while :; do
    printf 'Toggle eligible numbers, all / none / defaults, Enter to review, q to quit: '
    IFS= read -r answer <&3 || die 'Input ended; no changes applied'
    case "$answer" in
      '') break ;;
      q|quit) return 1 ;;
      all) SELECTED=" ${COMPONENTS[*]} " ;;
      none) SELECTED=' ' ;;
      defaults) SELECTED="$DEFAULTS" ;;
      *) while IFS= read -r token; do
        case "$token" in
          1|2|3|4|5|6|7|8|9|10|11)
            index=$((token-1)); item="${COMPONENTS[$index]}"
            if ! mac_eligible "$index"; then printf '%s is locked; no change.\n' "$item"
            elif mac_selected "$item"; then mac_deselect "$item"
            else mac_select "$item"; fi ;;
          *) printf 'Unknown selection: %s\n' "$token" ;;
        esac
      done < <(mac_selection_words "$answer") ;;
    esac
    mac_normalize
    mac_inventory
  done
}
