#!/usr/bin/env bash
# 80-auto-updates.sh — automatic security patches via unattended-upgrades.
[ -n "${_VPS_COMMON_LOADED:-}" ] || { echo "run via setup.sh" >&2; exit 1; }

if ! dpkg -s unattended-upgrades >/dev/null 2>&1; then
  log "Installing unattended-upgrades"
  $SUDO apt-get install -y unattended-upgrades >/dev/null
fi

# Enable the daily apt timers that drive unattended security upgrades.
$SUDO tee /etc/apt/apt.conf.d/20auto-upgrades >/dev/null <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
$SUDO systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
ok "unattended-upgrades enabled (security patches install automatically)"
