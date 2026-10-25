#!/usr/bin/env bash
# Presentation only. Selection/dependency validation stays in lib/onboarding.sh.
on_locked_inventory() {
  local i=0
  printf '\nAlready present / manual repair (read-only)\n'
  while [ "$i" -lt "${#COMPONENTS[@]}" ]; do
    if ! on_eligible "$i"; then
      printf '  %-22s %s — %s\n' "${LABELS[$i]}" "${STATES[$i]}" "${DETAILS[$i]}"
    fi
    i=$((i+1))
  done
}

on_gum_pick() {
  local i="$1" end="$2" title="$3" id defaults='' offered=' ' output
  local options=()
  while [ "$i" -lt "$end" ]; do
    id="${COMPONENTS[$i]}"
    if on_eligible "$i" && [ "$id:$SHELL_REQUIRED" != shell:1 ]; then
      options[${#options[@]}]="${LABELS[$i]}|$id"
      offered="$offered$id "
      if on_selected "$id"; then defaults="${defaults:+$defaults,}${LABELS[$i]}"; fi
    fi
    i=$((i+1))
  done
  [ "${#options[@]}" -gt 0 ] || return 0
  # Keep stage instructions inside Gum so its renderer clears them on exit.
  # Gum supplies the keyboard help while the checklist is active.
  if ! output="$(ui_gum choose --no-limit --height 11 --header "$title" \
    --selected="$defaults" --selected-prefix '[x] ' --cursor-prefix '[ ] ' \
    --unselected-prefix '[ ] ' --label-delimiter '|' --output-delimiter $'\n' \
    --timeout=0 --ordered=false "${options[@]}")"; then return 1; fi
  # A successful empty result means select none, not cancellation.
  while IFS= read -r id; do on_deselect "$id"; done < <(on_selection_words "$offered")
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    case "$offered" in *" $id "*) on_select "$id" ;; *) return 1 ;; esac
  done <<< "$output"
}

on_gum_menu() {
  local id config_title='Choose configuration updates'
  SHELL_REQUIRED=0
  on_gum_pick 0 9 'Choose tools to install' || return 1
  # Wait until both pages are complete before adding shortcut dependencies.
  # Otherwise a default shortcut can reselect tmux even when both are later off.
  on_config_state shell
  STATES[10]="$DETECTED"; DETAILS[10]="$DETAIL"
  # Required shell integration is displayed as a dependency, not a checkbox.
  for id in tailscale mosh tmux git gh codex claude node bun; do
    if on_selected "$id" && [ "${STATES[10]}" != broken ]; then SHELL_REQUIRED=1; break; fi
  done
  if [ "$SHELL_REQUIRED" = 1 ]; then
    STATES[10]=update; DETAILS[10]='Needs configuration for selected installation'
    on_select shell
    config_title="$config_title"$'\nShell integration: required for selected tools.'
  fi
  on_gum_pick 9 "${#COMPONENTS[@]}" "$config_title" || return 1
  on_normalize
}

