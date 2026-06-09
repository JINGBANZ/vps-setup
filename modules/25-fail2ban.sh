#!/usr/bin/env bash
# 25-fail2ban.sh — ban IPs after repeated failed SSH logins.
[ -n "${_VPS_COMMON_LOADED:-}" ] || { echo "run via setup.sh" >&2; exit 1; }

# `backend = systemd` (below) reads bans from the journal, which requires the
# python3-systemd bindings. fail2ban only *Suggests* that package, so on a fresh
# box it's missing and the sshd jail fails to start ("No module named 'systemd'")
# — silently leaving SSH unprotected. Install both together so the jail works.
f2b_missing=()
have fail2ban-client || f2b_missing+=(fail2ban)
dpkg -s python3-systemd >/dev/null 2>&1 || f2b_missing+=(python3-systemd)
if [ "${#f2b_missing[@]}" -gt 0 ]; then
  log "Installing: ${f2b_missing[*]}"
  $SUDO apt-get install -y "${f2b_missing[@]}" >/dev/null
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
