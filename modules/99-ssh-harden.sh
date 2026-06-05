#!/usr/bin/env bash
# 99-ssh-harden.sh — optionally switch SSH to key-only login. Interactive.
#
# ROOT IS NEVER LOCKED OUT:
#   * We never set 'PermitRootLogin no' — root stays reachable BY KEY
#     (prohibit-password).
#   * Before disabling password auth we make sure root has a key; if none can be
#     obtained, we leave password auth ON rather than risk a lockout.
#   * The sshd config is validated with `sshd -t` and reverted if invalid.
#
# The drop-in is named 00-hardening.conf ON PURPOSE: sshd_config is FIRST-match-
# wins, so it must sort BEFORE Ubuntu's 50-cloud-init.conf (which may set
# `PasswordAuthentication yes`) for our `no` to take effect. We then assert the
# effective value with `sshd -T` and warn if something still overrides it.
[ -n "${_VPS_COMMON_LOADED:-}" ] || { echo "run via setup.sh" >&2; exit 1; }

HARDENING_CONF=/etc/ssh/sshd_config.d/00-hardening.conf

# True if root has at least one *valid* key (not just a non-empty file).
root_has_key() { $SUDO grep -qsE "$SSH_KEY_RE" /root/.ssh/authorized_keys 2>/dev/null; }

if ! ask_yes_no "Harden SSH to key-only login (disable password auth)?" "y"; then
  skip "SSH hardening (declined) — password login left enabled"
  return 0 2>/dev/null || exit 0
fi

# Resolve key(s) (root's / target user's, else paste). Needed so we never lock out.
key="$(get_ssh_public_key)"

# Guarantee root keeps a way in: if root has no valid key but we have one,
# install it for root so 'prohibit-password' still lets root log in.
if [ -n "$key" ] && ! root_has_key; then
  install_authorized_key root "$key"
  log "Installed an SSH key for root so it stays reachable after hardening"
fi

# Only disable passwords if root can get in by key now — otherwise bail safely.
if ! root_has_key; then
  warn "No valid SSH key for root — leaving password authentication ON to avoid lockout."
  warn "Add a key (ssh-copy-id) and re-run to enable key-only SSH."
  return 0 2>/dev/null || exit 0
fi

# Write a drop-in (never clobber the distro's sshd_config), but only when it
# differs — so re-runs don't validate/reload sshd needlessly.
$SUDO install -d -m 0755 /etc/ssh/sshd_config.d
if write_config "$HARDENING_CONF" <<'EOF'
# Managed by vps-setup/setup.sh — key-only SSH. Root stays reachable by key.
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF
then
  # Config changed — validate before reloading; never reload a broken config.
  if $SUDO sshd -t; then
    $SUDO systemctl reload-or-restart ssh  >/dev/null 2>&1 \
      || $SUDO systemctl reload-or-restart sshd >/dev/null 2>&1 || true
    # Assert the setting actually took effect — another drop-in could override it.
    if $SUDO sshd -T 2>/dev/null | grep -qiE '^passwordauthentication[[:space:]]+no'; then
      ok "SSH hardened (password auth off; root reachable by key only)"
    else
      warn "Wrote $HARDENING_CONF, but sshd still reports password auth ENABLED."
      warn "Another drop-in is overriding it — check /etc/ssh/sshd_config.d/ (e.g. 50-cloud-init.conf)."
    fi
  else
    warn "sshd config test failed — reverting hardening, leaving SSH unchanged."
    $SUDO rm -f "$HARDENING_CONF"
  fi
else
  skip "SSH hardening (already applied)"
fi
