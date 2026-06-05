#!/usr/bin/env bash
# 60-firewall.sh — ufw: default-deny inbound, but allow SSH/mosh/Tailscale
# FIRST so enabling the firewall can never lock us out.
[ -n "${_VPS_COMMON_LOADED:-}" ] || { echo "run via setup.sh" >&2; exit 1; }

# ufw is normally installed by 10-apt-tools.sh; install it here too so this
# module is self-contained and doesn't silently no-op if ufw is missing.
if ! have ufw; then
  log "Installing ufw"
  $SUDO apt-get install -y ufw >/dev/null
fi

log "Configuring ufw firewall"
$SUDO ufw allow "${SSH_PORT}/tcp"    >/dev/null            # SSH — open before enabling
$SUDO ufw allow 60000:61000/udp      >/dev/null            # mosh
$SUDO ufw allow in on tailscale0     >/dev/null 2>&1 || true   # trust the tailnet
$SUDO ufw default deny incoming      >/dev/null
$SUDO ufw default allow outgoing     >/dev/null
$SUDO ufw --force enable             >/dev/null
ok "ufw enabled (allow SSH ${SSH_PORT}/tcp, mosh, tailscale0; deny other inbound)"
