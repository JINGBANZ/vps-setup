#!/usr/bin/env bash
# 15-ssh-hardening.sh — disable SSH password logins (key-only), keeping key
# auth fully working. Bots brute-forcing port 22 with passwords get nothing.
#
# SAFETY GUARD: we only disable password auth if an authorized SSH key already
# exists for the login user or root. On a password-only box (no key installed)
# we SKIP and warn — turning passwords off there would lock you out for good.
[ -n "${_VPS_COMMON_LOADED:-}" ] || { echo "run via setup.sh" >&2; exit 1; }

# True if any common authorized_keys file holds a real public key line.
authkey_present() {
  local f
  for f in "$TARGET_HOME/.ssh/authorized_keys" /root/.ssh/authorized_keys; do
    $SUDO test -s "$f" 2>/dev/null || continue
    $SUDO grep -qiE '(ssh-(ed25519|rsa|dss)|ecdsa-sha2-|sk-(ssh|ecdsa))' "$f" 2>/dev/null \
      && return 0
  done
  return 1
}

if ! authkey_present; then
  warn "No authorized SSH key found for $TARGET_USER or root."
  skip "SSH hardening (would lock you out without a key — add one, then re-run)"
  return 0 2>/dev/null || exit 0
fi

# sshd lives in /usr/sbin, which isn't always on a non-login PATH; resolve it so
# `sshd -t` validation can't spuriously fail and revert a good config.
SSHD_BIN="$(command -v sshd 2>/dev/null || echo /usr/sbin/sshd)"

# Desired hardening. KbdInteractiveAuthentication no closes the PAM/keyboard-
# interactive backdoor that can otherwise still prompt for a password.
read -r -d '' HARDENING <<'EOF' || true
# Managed by vps-setup/setup.sh — key-only SSH, no passwords.
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF

# Modern Debian/Ubuntu sshd_config has `Include /etc/ssh/sshd_config.d/*.conf`
# near the top. A drop-in is cleaner and reversible (delete the file). We prefix
# 00- so it sorts before 50-cloud-init.conf: sshd uses the FIRST value it reads
# for each keyword, so our file must win over cloud-init's PasswordAuthentication.
DROPIN=/etc/ssh/sshd_config.d/00-vps-hardening.conf
applied=0

if $SUDO grep -qiE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' \
     /etc/ssh/sshd_config 2>/dev/null; then
  if printf '%s\n' "$HARDENING" | write_config "$DROPIN" 0644; then
    log "Hardening sshd (drop-in: $DROPIN)"
    # Validate the *combined* config before reload. If it fails, pull our file
    # back out so a bad drop-in is never left active for the next reload/reboot.
    if $SUDO "$SSHD_BIN" -t 2>/dev/null; then
      applied=1
    else
      $SUDO rm -f "$DROPIN"
      warn "sshd -t rejected the hardening drop-in; reverted, sshd untouched"
    fi
  else
    skip "SSH hardening (drop-in already in place)"
  fi
else
  # Older sshd with no Include: edit the main file in place. Only touch lines
  # that aren't already at the target value, so re-runs don't churn.
  cfg=/etc/ssh/sshd_config
  $SUDO grep -q '^PasswordAuthentication no'        "$cfg" || { $SUDO sed -i 's/^#*[[:space:]]*PasswordAuthentication.*/PasswordAuthentication no/'        "$cfg"; applied=1; }
  $SUDO grep -q '^KbdInteractiveAuthentication no'  "$cfg" || { $SUDO sed -i 's/^#*[[:space:]]*KbdInteractiveAuthentication.*/KbdInteractiveAuthentication no/' "$cfg"; applied=1; }
  $SUDO grep -q '^PermitRootLogin prohibit-password' "$cfg" || { $SUDO sed -i 's/^#*[[:space:]]*PermitRootLogin.*/PermitRootLogin prohibit-password/'           "$cfg"; applied=1; }
  if [ "$applied" -eq 1 ]; then
    log "Hardening sshd (edited $cfg)"
    $SUDO "$SSHD_BIN" -t 2>/dev/null || { warn "sshd -t failed after edit — NOT reloading; review $cfg"; applied=0; }
  fi
fi

if [ "$applied" -eq 1 ]; then
  # reload (not restart) is enough for auth-policy changes and won't drop your
  # current session. Unit is `ssh` on Debian/Ubuntu (not `sshd`).
  $SUDO systemctl reload ssh >/dev/null 2>&1 || $SUDO systemctl reload sshd >/dev/null 2>&1 || true
  ok "SSH hardened (key-only login; password & root-password logins disabled)"
else
  skip "SSH hardening (already key-only)"
fi
