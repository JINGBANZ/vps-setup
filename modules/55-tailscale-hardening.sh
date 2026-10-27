#!/usr/bin/env bash
# Apply Tailscale's SSH-forwarding mitigation without changing login or node state.
[ -n "${_VPS_COMMON_LOADED:-}" ] || { echo "run via setup.sh" >&2; exit 1; }

tailscale_forwarding_disabled() {
  local pid
  pid="$(systemctl show tailscaled.service --property=MainPID --value)" || return 1
  case "$pid" in ''|0|*[!0-9]*) return 1 ;; esac
  # Inspect only this boolean; never print the daemon's environment or secrets.
  $SUDO sh -c 'tr "\000" "\n" < "/proc/$1/environ" | grep -qx "TS_SSH_DISABLE_FORWARDING=1"' sh "$pid" 2>/dev/null
}

if [ "$(systemctl show tailscaled.service --property=LoadState --value)" != loaded ]; then
  warn 'Tailscale hardening requires the installed tailscaled.service systemd unit.'
  exit 1
fi

changed=0
if write_config /etc/systemd/system/tailscaled.service.d/90-vps-setup-no-forwarding.conf 0644 <<'EOF'
# Managed by vps-setup. Keep Tailscale SSH, disable its forwarding features.
[Service]
Environment="TS_SSH_DISABLE_FORWARDING=1"
EOF
then
  changed=1
fi
# Reload even on reruns: a previous attempt may have written the file but failed
# before notifying systemd. This does not restart services or interrupt sessions.
$SUDO systemctl daemon-reload

if systemctl is-active --quiet tailscaled.service; then
  if [ "$changed" = 1 ] || ! tailscale_forwarding_disabled; then
    log 'Restarting tailscaled to disable SSH forwarding; Tailscale sessions may disconnect'
    $SUDO systemctl restart tailscaled.service
  fi
  if ! systemctl is-active --quiet tailscaled.service || ! tailscale_forwarding_disabled; then
    warn 'Tailscale forwarding mitigation could not be verified. Check service status and conflicting environment files/drop-ins.'
    exit 1
  fi
  ok 'Tailscale SSH forwarding disabled in the running daemon'
else
  ok 'Tailscale forwarding mitigation configured; service left stopped (applies on next start)'
fi
warn 'This mitigates several SSH issues; install the vendor-confirmed patched Tailscale release when available.'
