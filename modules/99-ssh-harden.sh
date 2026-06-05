#!/usr/bin/env bash
# 99-ssh-harden.sh — key-only SSH. Runs LAST so an admin user (90) already
# exists as a fallback before we touch root login.
#
# Safety:
#   * Skipped entirely if no authorized_keys exists anywhere -> no lockout.
#   * Root stays reachable by key (prohibit-password) unless DISABLE_ROOT_LOGIN=1
#     AND an admin user with a key exists.
#   * Config validated with `sshd -t`; reverted if invalid before any reload.
[ -n "${_VPS_COMMON_LOADED:-}" ] || { echo "run via setup.sh" >&2; exit 1; }

log "Hardening SSH (key-only auth)"

# Refuse to harden if there's no key to log in with — would lock you out.
key_found=0
for kf in /root/.ssh/authorized_keys "$TARGET_HOME/.ssh/authorized_keys"; do
  [ -s "$kf" ] && key_found=1
done
if [ -n "$ADMIN_USER" ]; then
  admin_home="$(getent passwd "$ADMIN_USER" | cut -d: -f6)"
  [ -s "$admin_home/.ssh/authorized_keys" ] && key_found=1
fi

if [ "$key_found" -ne 1 ]; then
  warn "No SSH authorized_keys found — SKIPPING SSH hardening to avoid lockout."
  warn "Add your key (ssh-copy-id) and re-run to enable key-only SSH."
  return 0 2>/dev/null || exit 0
fi

# Decide the root-login policy.
root_policy="prohibit-password"   # default: root reachable by key (safe fallback)
if [ "$DISABLE_ROOT_LOGIN" = "1" ]; then
  if [ -n "$ADMIN_USER" ] \
     && [ -s "$(getent passwd "$ADMIN_USER" | cut -d: -f6)/.ssh/authorized_keys" ]; then
    root_policy="no"
  else
    warn "DISABLE_ROOT_LOGIN=1 ignored: need an admin user with an SSH key as fallback."
  fi
fi

# Write a drop-in so we never clobber the distro's sshd_config.
$SUDO install -d -m 0755 /etc/ssh/sshd_config.d
$SUDO tee /etc/ssh/sshd_config.d/99-hardening.conf >/dev/null <<EOF
# Managed by vps-setup/setup.sh — key-only SSH.
PermitRootLogin ${root_policy}
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF

# Validate before reloading; never reload a broken config.
if $SUDO sshd -t; then
  $SUDO systemctl reload ssh  >/dev/null 2>&1 \
    || $SUDO systemctl reload sshd >/dev/null 2>&1 || true
  ok "SSH hardened (password auth off; root: ${root_policy})"
else
  warn "sshd config test failed — reverting hardening, leaving SSH unchanged."
  $SUDO rm -f /etc/ssh/sshd_config.d/99-hardening.conf
fi
