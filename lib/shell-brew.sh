#!/usr/bin/env bash
# Appended to managed path.sh. Compatible with Bash 3.2 and Zsh.
# shellcheck disable=SC2154
# Use Homebrew's full environment, not a hand-written subset of its exports.
# Keep the guard shell-local: child shells must initialize their own environment.
_vps_setup_brew_needed=0
if [ "${_VPS_SETUP_BREW_LOADED:-}" != "$_vps_setup_brew" ]; then
  _vps_setup_brew_needed=1
else
  for _vps_setup_dir in "${_vps_setup_brew%/bin/brew}/bin" "${_vps_setup_brew%/bin/brew}/sbin"; do
    case ":$PATH:" in *:"$_vps_setup_dir":*) ;; *) _vps_setup_brew_needed=1 ;; esac
  done
fi
if [ "$_vps_setup_brew_needed" = 1 ] && [ -x "$_vps_setup_brew" ]; then
  # brew itself starts Bash. Avoid recursively sourcing this file when a batch
  # job explicitly uses it as BASH_ENV; clear only the child command's hooks.
  if _vps_setup_brew_env="$(BASH_ENV='' ENV='' "$_vps_setup_brew" shellenv sh)"; then
    eval "$_vps_setup_brew_env"
    _VPS_SETUP_BREW_LOADED="$_vps_setup_brew"
  fi
fi
unset _vps_setup_brew _vps_setup_brew_needed _vps_setup_brew_env _vps_setup_dir
