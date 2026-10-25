#!/usr/bin/env bash
# 10-apt-tools.sh — base CLI tools via apt: git, curl, unzip, tmux, mosh, ufw.
# (unzip must exist before Bun is installed in 60-node-bun.sh.)
[ -n "${_VPS_COMMON_LOADED:-}" ] || { echo "run via setup.sh" >&2; exit 1; }

# Explicit onboarding list prevents unrelated unchecked tools being installed.
# Retain defaults for callers sourcing this module independently.
if [ "${ONBOARDING_APT_PACKAGES+x}" = x ]; then
  APT_PKGS=()
  read -r -a APT_PKGS <<< "$ONBOARDING_APT_PACKAGES" || true
else
  APT_PKGS=(git curl unzip tmux mosh ufw)
fi

missing=()
for pkg in "${APT_PKGS[@]}"; do
  if have "$pkg"; then skip "$pkg"; else missing+=("$pkg"); fi
done

if [ "${#missing[@]}" -gt 0 ]; then
  log "Installing via apt: ${missing[*]}"
  export DEBIAN_FRONTEND=noninteractive
  apt_get update -y
  apt_get install -y "${missing[@]}"
  ok "apt packages installed"
fi
