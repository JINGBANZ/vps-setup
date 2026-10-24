#!/usr/bin/env bash
# Helpers for macOS; sourcing this file performs no actions.
COMPONENTS=(tailscale ssh mosh tmux shortcut git gh codex claude node bun screen power)
LABELS=('Tailscale' 'Remote Login guide' 'Mosh' 'tmux' 'Session shortcut: t' 'Git' 'GitHub CLI' 'Codex' 'Claude Code' 'Node.js / nvm' 'Bun' 'Screen Sharing guide' 'Always-on power settings')
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
mac_usage() {
  cat <<'EOF'
Usage on macOS: bash setup.sh [options]  (run WITHOUT sudo)
  No options          Detect tools, choose components, review, then confirm.
  --check             Read-only inventory and Tailscale IP.
  --dry-run           Read-only plan using defaults or last saved choices.
  --select LIST       Exact comma-separated component IDs, or none.
  --yes               Apply an explicit --select list without menu confirmation.
  --help              Show this help.
Components:
  tailscale,ssh,mosh,tmux,shortcut,git,gh,codex,claude,node,bun,screen,power
Node and Bun default off. SSH and Screen Sharing are guided macOS settings.
Deselecting means skip; existing software and settings are kept.
Examples:
  bash setup.sh --select mosh,tmux,codex --dry-run
  bash setup.sh --select mosh,tmux,codex --yes
EOF
}
mac_selected() { case "$SELECTED" in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
mac_select() { if ! mac_selected "$1"; then SELECTED="$SELECTED$1 "; fi; }
mac_deselect() { SELECTED="${SELECTED// $1 / }"; }
mac_parse_selection() {
  local value="$1" id known item
  SELECTED=' '
  [ "$value" != none ] || return 0
  [ -n "$value" ] || die 'Empty selection; use none explicitly'
  for id in ${value//,/ }; do
    known=0
    for item in "${COMPONENTS[@]}"; do [ "$id" != "$item" ] || known=1; done
    [ "$known" = 1 ] || die "Unknown component: $id"
    mac_select "$id"
  done
}
mac_find_brew() {
  BREW_BIN="$(command -v brew || true)"
  if [ -z "$BREW_BIN" ]; then
    for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
      if [ -x "$candidate" ]; then BREW_BIN="$candidate"; break; fi
    done
  fi
  if [ -n "$BREW_BIN" ]; then eval "$("$BREW_BIN" shellenv)"; fi
}
mac_tool() {
  local name="$1" bin flag=--version
  bin="$(command -v "$name" || true)"
  [ -n "$bin" ] || return 1
  # Apple's git placeholder can launch the CLT UI; do not run it in discovery.
  [ "$bin:$CLT_READY" != /usr/bin/git:0 ] || return 1
  [ "$name" != tmux ] || flag=-V
  "$bin" "$flag" >/dev/null 2>&1 || return 1
  printf '%s\n' "$bin"
}
mac_discover() {
  CLT_READY=0
  if xcode-select -p >/dev/null 2>&1; then CLT_READY=1; fi
  mac_find_brew
  export PATH="$HOME/.local/bin:$HOME/.bun/bin:$PATH"
  export NVM_DIR="${NVM_DIR:-$([ -z "${XDG_CONFIG_HOME:-}" ] && printf %s "$HOME/.nvm" || printf %s "$XDG_CONFIG_HOME/nvm")}"
  if [ -s "$NVM_DIR/nvm.sh" ]; then
    # shellcheck disable=SC1091
    . "$NVM_DIR/nvm.sh" --no-use
    nvm use --silent default >/dev/null 2>&1 || true
  fi
  mac_detect_tailscale
}
mac_detect_tailscale() {
  local app gui=0 system_brew=0 system_other=0 user_service=0
  TS_BIN="$(command -v tailscale || true)"
  for app in /Applications/Tailscale.app "$HOME/Applications/Tailscale.app"; do
    if [ -d "$app" ]; then
      gui=1
      if [ -z "$TS_BIN" ] && [ -x "$app/Contents/MacOS/Tailscale" ]; then TS_BIN="$app/Contents/MacOS/Tailscale"; fi
    fi
  done
  if launchctl print system/homebrew.mxcl.tailscale >/dev/null 2>&1; then system_brew=1; fi
  if launchctl print system/com.tailscale.tailscaled >/dev/null 2>&1; then system_other=1; fi
  if launchctl print "gui/$(id -u)/homebrew.mxcl.tailscale" >/dev/null 2>&1; then user_service=1; fi
  TS_KIND=missing
  if [ "$((gui+system_brew+system_other+user_service))" -gt 1 ]; then TS_KIND=conflict
  elif [ "$gui" = 1 ]; then TS_KIND=gui
  elif [ "$system_brew" = 1 ]; then TS_KIND=system
  elif [ "$system_other" = 1 ]; then TS_KIND=external
  elif [ "$user_service" = 1 ]; then TS_KIND=user
  elif [ -n "$BREW_BIN" ] && "$BREW_BIN" list --formula tailscale >/dev/null 2>&1; then TS_KIND=stopped
  elif [ -n "$TS_BIN" ]; then TS_KIND=external
  fi
  TS_AUTH=unknown
  if [ -n "$TS_BIN" ]; then
    TS_AUTH="$("$TS_BIN" status --json 2>/dev/null | plutil -extract BackendState raw -o - - 2>/dev/null)" || TS_AUTH=unknown
  fi
}
mac_power_value() {
  pmset -g custom | awk -v key="$1" '
    /^AC Power:/ { ac=1; next }
    /^[^[:space:]]/ { ac=0 }
    ac && $1 == key { print $2; exit }
  '
}
mac_status() {
  local id="$1" bin version label flag=--version
  case "$id" in
    tailscale) printf '%s; authentication=%s' "$TS_KIND" "$TS_AUTH" ;;
    ssh|screen)
      label=com.openssh.sshd
      [ "$id" != screen ] || label=com.apple.screensharing
      if launchctl print "system/$label" >/dev/null 2>&1; then printf 'Service loaded; verify allowed users'
      else printf 'Built in; check Sharing settings'; fi ;;
    power) printf 'AC sleep=%s; autorestart=%s' "$(mac_power_value sleep)" "$(mac_power_value autorestart)" ;;
    shortcut)
      if [ -f "$CONFIG_DIR/tmux.sh" ]; then printf 'Managed shortcut present'
      else printf 'Not configured'; fi ;;
    *)
      if bin="$(mac_tool "$id")"; then
        [ "$id" != tmux ] || flag=-V
        version="$("$bin" "$flag" 2>&1 | head -n 1)" || version=unknown
        printf '%s [%s]' "$version" "$bin"
      else printf 'Missing / unavailable'; fi ;;
  esac
}
mac_inventory() {
  printf '\nMac mini setup — detected state (read-only)\n'
  printf 'Homebrew: %s\nCommand Line Tools ready: %s\n' "${BREW_BIN:-missing}" "$CLT_READY"
  local i=0
  while [ "$i" -lt "${#COMPONENTS[@]}" ]; do
    printf '  %-26s %s\n' "${LABELS[$i]}" "$(mac_status "${COMPONENTS[$i]}")"
    i=$((i+1))
  done
}
mac_menu() {
  local i=0 mark
  printf '\nChoose components (previous choices are remembered):\n'
  while [ "$i" -lt "${#COMPONENTS[@]}" ]; do
    mark=' '; if mac_selected "${COMPONENTS[$i]}"; then mark=x; fi
    printf ' %2s [%s] %-26s %s\n' "$((i+1))" "$mark" "${LABELS[$i]}" "$(mac_status "${COMPONENTS[$i]}")"
    i=$((i+1))
  done
}
mac_plan() {
  NEED_BREW=0
  printf '\nPlan — only selected components:\n'
  local id
  for id in "${COMPONENTS[@]}"; do
    if ! mac_selected "$id"; then continue; fi
    case "$id" in
      tailscale)
        case "$TS_KIND" in
          missing) NEED_BREW=1; printf '  tailscale: install Homebrew formula; start system service\n' ;;
          stopped) printf '  tailscale: start existing Homebrew formula as system service\n' ;;
          system) printf '  tailscale: keep loaded system service; verify sign-in\n' ;;
          conflict) printf '  tailscale: BLOCKED — conflicting installations; resolve locally or deselect\n' ;;
          *) printf '  tailscale: reuse %s installation; manual startup review (no migration)\n' "$TS_KIND" ;;
        esac ;;
      ssh|screen) printf '  %s: show macOS Sharing / allowed-user instructions\n' "$id" ;;
      power) printf '  power: set AC sleep=0 and supported autorestart=1 only if different\n' ;;
      shortcut) printf '  shortcut: create workspace; compare/update managed t() helper\n' ;;
      *)
        if mac_tool "$id" >/dev/null; then printf '  %s: reuse existing tool (no upgrade)\n' "$id"
        else
          printf '  %s: install\n' "$id"
          case "$id" in git|gh|tmux|mosh) NEED_BREW=1 ;; esac
        fi ;;
    esac
  done
  if [ "$NEED_BREW" = 1 ]; then printf '  Homebrew dependency: %s\n' "${BREW_BIN:-install once}"; fi
  if [ "$SELECTED" != ' ' ]; then printf '  Compare managed shell configuration; back up changed files; save choices.\n'; fi
  printf 'Deselected components are skipped. Sign-in and protected Sharing settings remain interactive.\n'
}
mac_ensure_brew() {
  if [ -z "$BREW_BIN" ]; then
    local installer
    installer="$(mktemp)"
    curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh -o "$installer"
    /bin/bash "$installer"
    rm -f "$installer"
    mac_find_brew
  fi
  [ -n "$BREW_BIN" ] || die 'Homebrew not found after installation; rerun after fixing it'
}
mac_tailscale() {
  case "$TS_KIND" in
    missing|stopped)
      if [ "$TS_KIND" = missing ]; then "$BREW_BIN" install --formula tailscale; fi
      sudo "$BREW_BIN" services start tailscale
      launchctl print system/homebrew.mxcl.tailscale >/dev/null 2>&1 || die 'Tailscale service did not load; check sudo brew services info tailscale, then rerun' ;;
    system) skip 'Tailscale system service (already loaded)' ;;
    *) warn "Keeping $TS_KIND Tailscale. Review pre-login startup locally; do not run a second variant." ;;
  esac
  mac_detect_tailscale
}
mac_write() {
  local source="$1" target="$2" stage
  if cmp -s "$source" "$target"; then return 0; fi
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
mac_power() {
  local key wanted cap backup
  cap="$(pmset -g cap)"
  for key in sleep autorestart; do
    wanted=0
    if [ "$key" = autorestart ]; then
      wanted=1
      if ! printf '%s\n' "$cap" | grep -Eq '^[[:space:]]*autorestart[[:space:]]*$'; then
        warn 'Automatic power-on is not exposed by pmset; check System Settings > Energy.'; continue
      fi
    fi
    if [ "$(mac_power_value "$key")" = "$wanted" ]; then continue; fi
    backup="$CONFIG_DIR/power-settings-before.txt"
    if [ ! -e "$backup" ]; then (umask 077; pmset -g custom > "$backup"); fi
    sudo pmset -c "$key" "$wanted"
    [ "$(mac_power_value "$key")" = "$wanted" ] || die "Power setting $key did not apply"
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
  if [ -f "$CONFIG_DIR/tmux.sh" ]; then
    printf -v tmux_quote '%q' "$CONFIG_DIR/tmux.sh"
    printf '. %s\n' "$tmux_quote" >> "$env_tmp"
  fi
  mac_write "$env_tmp" "$env_file"
  rm -f "$env_tmp"
  printf -v quoted '%q' "$env_file"
  line="[ ! -f $quoted ] || . $quoted # vps-setup:macos"
  bash_profile="$HOME/.bash_profile"
  for profile in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
    if [ -f "$profile" ]; then bash_profile="$profile"; break; fi
  done
  mkdir -p "${ZDOTDIR:-$HOME}"
  for profile in "${ZDOTDIR:-$HOME}/.zprofile" "${ZDOTDIR:-$HOME}/.zshrc" "$bash_profile" "$HOME/.bashrc"; do
    profile_tmp="$(mktemp)"
    if [ -f "$profile" ]; then sed '/ # vps-setup:macos$/d' "$profile" > "$profile_tmp"; fi
    printf '%s\n' "$line" >> "$profile_tmp"
    mac_write "$profile_tmp" "$profile"
    rm -f "$profile_tmp"
  done
}
mac_addresses() {
  local ip
  if [ -n "$TS_BIN" ] && [ "$TS_AUTH" = Running ]; then
    ip="$("$TS_BIN" ip -4 2>/dev/null)" || ip=''
    if [ -n "$ip" ]; then
      printf '\nTailscale IPv4: %s\nTerminal: mosh %s@%s\nScreen Sharing address: %s\n' "$ip" "$TARGET_USER" "$ip" "$ip"
      return 0
    fi
  fi
  printf '\nTailscale address not verified. Finish sign-in, then rerun bash setup.sh --check.\n'
}
mac_finish() {
  printf '\nOpen a new terminal to load managed shell configuration.\n'
  if mac_selected ssh; then printf 'Remote Login: System Settings > General > Sharing; allow only your account.\n'; fi
  if mac_selected screen; then printf 'Screen Sharing: enable it in Sharing; allow your local Mac account. Different Apple IDs are fine.\n'; fi
  if mac_selected tailscale; then
    case "$TS_KIND" in
      system|stopped|missing) printf 'Tailscale sign-in, if needed: sudo tailscale up\n' ;;
      *) printf 'Tailscale sign-in: use your existing app or daemon; review unattended startup.\n' ;;
    esac
    printf 'Install Tailscale on the laptop and join the same tailnet. Tailscale assigns the address automatically.\n'
    mac_addresses
  fi
  if mac_selected gh; then printf 'GitHub authentication, if needed: gh auth login\n'; fi
  if mac_selected codex; then printf 'Codex authentication, if needed: codex\n'; fi
  if mac_selected claude; then printf 'Claude authentication, if needed: claude\n'; fi
  if mac_selected mosh; then printf 'Install Mosh on the laptop too; SSH authenticates, then Mosh uses UDP.\n'; fi
  if mac_selected shortcut; then printf 'On the mini: t my-task, then run your agent. Ctrl-b, d detaches.\n'; fi
  printf 'tmux survives disconnects, not Mac reboots. Display sleep is fine; system sleep suspends work.\n'
  printf 'Test external access and reboot recovery. FileVault unlock may need an independent network path.\n'
  printf 'See macos/README.md for firewall rules, recovery and verification.\n'
}
