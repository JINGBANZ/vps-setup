#!/usr/bin/env bash
# 50-tailscale.sh — Tailscale via the official install script.
[ -n "${_VPS_COMMON_LOADED:-}" ] || { echo "run via setup.sh" >&2; exit 1; }

if have tailscale; then
  skip "tailscale ($(tailscale version 2>/dev/null | head -1))"
else
  log "Installing Tailscale"
  curl -fsSL https://tailscale.com/install.sh | $SUDO sh
  ok "tailscale installed — run 'sudo tailscale up' to authenticate"
fi
