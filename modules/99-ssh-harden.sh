#!/usr/bin/env bash
# 99-ssh-harden.sh — optionally switch SSH to key-only login. Interactive.
#
# ROOT IS NEVER LOCKED OUT:
#   * We never set 'PermitRootLogin no' — root stays reachable BY KEY
#     (prohibit-password).
#   * Before disabling password auth we make sure root has a key; if none can be
#     obtained, we leave password auth ON rather than risk a lockout.
#   * The sshd config is validated with `sshd -t` and reverted if invalid.
[ -n "${_VPS_COMMON_LOADED:-}" ] || { echo "run via setup.sh" >&2; exit 1; }

if ! ask_yes_no "Harden SSH to key-only login (disable password auth)?" "y"; then
  skip "SSH hardening (declined) — password login left enabled"
  return 0 2>/dev/null || exit 0
fi

# Resolve a key (root's / target user's, else paste). Needed so we never lock out.
key="$(get_ssh_public_key)"

# Guarantee root keeps a way in: if root has no authorized_keys but we have a
# key, install it for root so 'prohibit-password' still lets root log in.
if [ -n "$key" ] && ! $SUDO test -s /root/.ssh/authorized_keys 2>/dev/null; then
  install_authorized_key root "$key"
  log "Installed an SSH key for root so it stays reachable after hardening"
fi

# Only disable passwords if root can get in by key now — otherwise bail safely.
if ! $SUDO test -s /root/.ssh/authorized_keys 2>/dev/null && [ -z "$key" ]; then
  warn "No SSH key available — leaving password authentication ON to avoid lockout."
  warn "Add a key (ssh-copy-id) and re-run to enable key-only SSH."
  return 0 2>/dev/null || exit 0
fi

# Write a drop-in so we never clobber the distro's sshd_config.
$SUDO install -d -m 0755 /etc/ssh/sshd_config.d
$SUDO tee /etc/ssh/sshd_config.d/99-hardening.conf >/dev/null <<'EOF'
# Managed by vps-setup/setup.sh — key-only SSH. Root stays reachable by key.
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF

# Validate before reloading; never reload a broken config.
if $SUDO sshd -t; then
  $SUDO systemctl reload ssh  >/dev/null 2>&1 \
    || $SUDO systemctl reload sshd >/dev/null 2>&1 || true
  ok "SSH hardened (password auth off; root reachable by key only)"
else
  warn "sshd config test failed — reverting hardening, leaving SSH unchanged."
  $SUDO rm -f /etc/ssh/sshd_config.d/99-hardening.conf
fi
