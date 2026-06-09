#!/usr/bin/env bash
# 30-auto-updates.sh — automatic security patches via unattended-upgrades.
[ -n "${_VPS_COMMON_LOADED:-}" ] || { echo "run via setup.sh" >&2; exit 1; }

if ! dpkg -s unattended-upgrades >/dev/null 2>&1; then
  log "Installing unattended-upgrades"
  $SUDO apt-get install -y unattended-upgrades >/dev/null
fi

# Enable the daily apt timers that drive unattended security upgrades.
# Written only if it differs from the current config.
if write_config /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
then
  ok "unattended-upgrades enabled (security patches install automatically)"
else
  skip "unattended-upgrades (already configured)"
fi

# Guarantee the security origin is allowed instead of relying on the distro's
# default 50unattended-upgrades (which we don't manage). `::` APPENDS to the
# Allowed-Origins list, so this adds -security without clobbering the defaults
# (a duplicate entry is harmless). ${distro_id}/${distro_codename} are expanded
# by unattended-upgrades itself.
if write_config /etc/apt/apt.conf.d/52unattended-upgrades-vps-security <<'EOF'
// Managed by vps-setup/setup.sh — ensure security updates are always allowed.
Unattended-Upgrade::Allowed-Origins:: "${distro_id}:${distro_codename}-security";
EOF
then
  ok "security origin asserted for unattended-upgrades"
else
  skip "security origin (already asserted)"
fi

# The daily apt timers are what actually run the upgrades (gated by the periodic
# values written above). They're enabled by default on Ubuntu; assert them here.
# NOTE: do NOT use `systemctl enable --now unattended-upgrades` — that unit only
# applies pending upgrades at *shutdown*, it does not drive the daily run.
$SUDO systemctl enable --now apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 || true
