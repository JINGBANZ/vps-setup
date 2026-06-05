#!/usr/bin/env bash
# 70-fail2ban.sh — ban IPs after repeated failed SSH logins.
[ -n "${_VPS_COMMON_LOADED:-}" ] || { echo "run via setup.sh" >&2; exit 1; }

if ! have fail2ban-client; then
  log "Installing fail2ban"
  $SUDO apt-get install -y fail2ban >/dev/null
fi
$SUDO systemctl enable --now fail2ban >/dev/null 2>&1 || true

# Write the jail only if it differs, and restart fail2ban ONLY when it changed.
if write_config /etc/fail2ban/jail.local <<EOF
# Managed by vps-setup/setup.sh
[sshd]
enabled  = true
backend  = systemd
port     = ${SSH_PORT}
maxretry = 3
findtime = 1h
bantime  = 24h
EOF
then
  log "Configuring fail2ban sshd jail"
  $SUDO systemctl restart fail2ban >/dev/null 2>&1 || true
  ok "fail2ban active (3 fails/hour -> 24h ban)"
else
  skip "fail2ban jail (already configured)"
fi
