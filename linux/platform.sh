#!/usr/bin/env bash
# Adapter outputs are consumed by lib/onboarding.sh and lib/setup.sh.
# shellcheck disable=SC2034
# Debian/Ubuntu adapter. Inventory is local; service changes require selection.
platform_init() {
  if [ "$(id -u)" = 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
    die 'Run setup without sudo as your normal user; selected Linux system modules request sudo when needed'
  fi
  command -v apt-get >/dev/null 2>&1 || die 'Linux support requires Debian/Ubuntu (apt-get)'
  COMPONENTS+=(security disk-guard runner postgres tailscale-hardening)
  LABELS+=('Linux security baseline' 'Disk guard (Docker cache cleanup)' 'GitHub Actions runner' 'Local PostgreSQL' 'Tailscale SSH forwarding protection')
  # Preserve Linux defaults, but show them explicitly and allow deselection.
  SELECTED="$SELECTED"'security disk-guard tailscale-hardening '
  [ -z "${GH_RUNNER_REPO:-}" ] || on_select runner
  [ "${DEV_POSTGRES:-0}" != 1 ] || on_select postgres
}
platform_discover() { CLT_READY=1; BREW_BIN=''; BREW_BROKEN=0; }
platform_detect_tool() { return 1; }
platform_detect_package() {
  local package="$1"
  [ "$package" != node ] || package=nodejs
  if dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -qx 'install ok installed'; then
    DETECTED=broken; DETAIL='Package installed but command unavailable; repair PATH manually'
    if [ "$package" = tailscale ]; then DETECTED=installed; DETAIL='Tailscale package present (kept; no service/auth checks)'; fi
  fi
}
platform_detect_extra() {
  DETECTED=update; DETAIL='Reconcile managed configuration; unchanged files are kept'
  case "$1" in
    tailscale-hardening) DETAIL='Disable Tailscale SSH forwarding; restart active tailscaled (sessions may disconnect)' ;;
    security) DETAIL='Review/reconcile SSH hardening, firewall, fail2ban and security updates' ;;
    disk-guard) DETAIL='Reconcile journal cap + timer; prunes Docker build cache/dangling images at threshold' ;;
    runner)
      DETECTED=missing; DETAIL='Opt-in; requires GH_RUNNER_REPO and registration credentials'
      if [ -e /opt/actions-runner/.runner ]; then DETECTED=installed; DETAIL='Registered runner present; kept without service checks'
      elif [ -e /opt/actions-runner ]; then DETECTED=broken; DETAIL='Existing runner directory; repair manually'; fi ;;
    postgres)
      DETECTED=missing; DETAIL='Opt-in; local socket + peer authentication'
      if dpkg-query -W -f='${Status}' postgresql 2>/dev/null | grep -qx 'install ok installed'; then
        DETECTED=installed; DETAIL='PostgreSQL package present; kept without service checks'
      fi ;;
  esac
}
platform_inventory() { printf 'Package manager: apt (Debian/Ubuntu)\n'; }
platform_installer_dependencies() {
  # Share dependency detection between the reviewed plan and installation.
  # Bootstrap can use wget/git, so curl is not necessarily present yet.
  local item packages=''
  if ! have curl; then
    for item in gh tailscale node bun codex claude runner; do
      if on_selected "$item"; then packages=curl; break; fi
    done
  fi
  if on_selected bun && ! have unzip; then packages="${packages:+$packages }unzip"; fi
  printf '%s' "$packages"
}
platform_plan() {
  local dependency
  while IFS= read -r dependency; do
    printf '  - Install %s (dependency, apt)\n' "$dependency"
  done < <(on_selection_words "$(platform_installer_dependencies)")
}
platform_plan_component() {
  case "$1" in
    tailscale-hardening)
      printf '  - Disable Tailscale SSH forwarding (systemd service environment)\n'
      printf '    Restart active tailscaled when needed; Tailscale sessions may disconnect. Verify backup access first.\n'
      printf '    Keep login credentials and SSH enabled; leave a stopped service stopped.\n' ;;
    security)
      printf '  - Configure Linux security\n'
      printf '    Key-only SSH when an authorized key exists; firewall allows SSH %s/tcp, Mosh UDP and tailscale0.\n' "$SSH_PORT"
      printf '    Enable fail2ban and automatic security updates.\n' ;;
    disk-guard)
      printf '  - Enable disk guard\n'
      printf '    Cap journal at 200 MB; prune Docker build cache and dangling images at %s%% disk usage.\n' "${DISK_GUARD_CLEAN_PCT:-90}" ;;
    runner)
      printf '  - Install GitHub Actions runner (%s)\n' "${GH_RUNNER_REPO:-set GH_RUNNER_REPO}"
      printf '    Install a system service; run repository workflows as ghrunner.\n' ;;
    postgres)
      printf '  - Install PostgreSQL (local socket, peer auth)\n'
      printf '    Database superuser: %s\n' "$TARGET_USER" ;;
  esac
}

platform_preflight() {
  if on_selected runner; then
    [ -n "${GH_RUNNER_REPO:-}" ] || die 'Set GH_RUNNER_REPO=owner/repo before selecting runner; no changes applied'
    case "$GH_RUNNER_REPO" in */*) ;; *) die 'GH_RUNNER_REPO must be owner/repo';; esac
    if [ -z "${GH_RUNNER_TOKEN:-}" ] && ! on_tool gh >/dev/null && ! on_selected gh; then
      die 'Runner requires GitHub CLI or GH_RUNNER_TOKEN; select gh as well'
    fi
  fi
  if on_selected security || on_selected disk-guard || on_selected runner || on_selected postgres || on_selected tailscale-hardening; then
    command -v systemctl >/dev/null 2>&1 || die 'Selected Linux system modules require systemd'
  fi
}
platform_run_module() {
  # Separate process: failed commands retain errexit even when caller handles failure.
  /bin/bash -eo pipefail -c '. "$1/lib/common.sh"; . "$1/$2"' _ "$REPO_ROOT" "$1"
}
platform_prepare() {
  local packages item need_apt=0
  if on_selected tailscale-hardening && [ -n "$SUDO" ]; then "$SUDO" -v || return 1; fi
  packages="$(platform_installer_dependencies)"
  for item in git tmux mosh; do if on_selected "$item"; then need_apt=1; fi; done
  if [ -n "$packages" ] || on_selected security || on_selected gh || on_selected tailscale || on_selected postgres || on_selected runner; then need_apt=1; fi
  if [ "$need_apt" = 1 ]; then
    if [ -n "$SUDO" ]; then "$SUDO" -v || return 1; fi
    apt_get update -y || return 1
  fi
  export ONBOARDING_APT_PACKAGES="$packages"
  if [ -n "$packages" ]; then platform_run_module modules/10-apt-tools.sh || return 1; fi
  # Preserve security-before-external-installers ordering when selected.
  if on_selected security; then
    for item in 15-ssh-hardening 20-firewall 25-fail2ban 30-auto-updates; do
      platform_run_module "modules/$item.sh" || return 1
    done
    RESULTS[11]='Completed — see module output'
  fi
  if on_selected disk-guard; then
    platform_run_module modules/35-disk-guard.sh || return 1
    RESULTS[12]='Completed — see module output'
  fi
}
platform_install_tool() {
  case "$1" in
    git|tmux|mosh) ONBOARDING_APT_PACKAGES="$1" platform_run_module modules/10-apt-tools.sh ;;
    gh) platform_run_module modules/40-gh.sh ;;
    tailscale) platform_run_module modules/50-tailscale.sh ;;
    *) return 1 ;;
  esac
}
platform_apply_extra() {
  local failed=0
  if on_selected tailscale-hardening; then
    if platform_run_module modules/55-tailscale-hardening.sh; then
      RESULTS[15]='Configured — see service verification above'
    else RESULTS[15]='Failed — forwarding mitigation not verified'; failed=1; fi
  fi
  if on_selected runner; then
    if platform_run_module modules/85-gh-runner.sh && [ -f /opt/actions-runner/.runner ]; then
      RESULTS[13]='Installed'
    else RESULTS[13]='Failed — inspect runner installation output'; failed=1; fi
  fi
  if on_selected postgres; then
    if DEV_POSTGRES=1 platform_run_module modules/90-postgres.sh; then
      platform_detect_extra postgres
      if [ "$DETECTED" = installed ]; then RESULTS[14]='Installed'
      else RESULTS[14]='Failed — PostgreSQL package missing'; failed=1; fi
    else RESULTS[14]='Failed — inspect PostgreSQL installation output'; failed=1; fi
  fi
  return "$failed"
}
platform_next_steps() {
  if [ "${RESULTS[0]}" = Installed ]; then on_next_step 'Tailscale sign-in: sudo tailscale up'; fi
}

