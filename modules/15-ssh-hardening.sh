#!/usr/bin/env bash
# 15-ssh-hardening.sh — disable SSH password logins (key-only), keeping key
# auth fully working. Bots brute-forcing port 22 with passwords get nothing.
#
# SAFETY GUARD: we only disable password auth if an authorized SSH key exists
# for the account you actually log in as ($TARGET_USER). On a password-only box
# we SKIP and warn — turning passwords off there would lock you out for good.
[ -n "${_VPS_COMMON_LOADED:-}" ] || { echo "run via setup.sh" >&2; exit 1; }

# True only if the LOGIN user ($TARGET_USER) has a usable public key. We check
# that account specifically — not root's — because disabling passwords locks you
# out precisely when YOUR account has no key. (When you run this as root,
# TARGET_HOME is /root, so root is covered.) Assumes the default
# AuthorizedKeysFile location (~/.ssh/authorized_keys).
authkey_present() {
  local f="$TARGET_HOME/.ssh/authorized_keys"
  $SUDO test -s "$f" 2>/dev/null \
    && $SUDO grep -qiE '(ssh-(ed25519|rsa|dss)|ecdsa-sha2-|sk-(ssh|ecdsa))' "$f" 2>/dev/null
}

if ! authkey_present; then
  warn "No authorized SSH key for $TARGET_USER (~/.ssh/authorized_keys)."
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
applied=0     # 1 once a real change is staged and validated
reverted=0    # 1 if we wrote a change but sshd -t rejected it (so we backed out)

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
      reverted=1
      warn "sshd -t rejected the hardening drop-in; reverted, sshd untouched"
    fi
  else
    skip "SSH hardening (drop-in already in place)"
  fi
else
  # Older sshd with no Include: edit the main file in place. Converge each
  # directive to its target value, ADDING it if the keyword is absent entirely
  # (a plain sed only rewrites existing lines and would silently skip a missing
  # directive — the worst failure mode for a hardening script). Idempotent: the
  # exact-line check short-circuits with no change on re-run.
  cfg=/etc/ssh/sshd_config
  ensure_directive() {   # $1 = keyword, $2 = full desired line
    $SUDO grep -qx "$2" "$cfg" && return 0           # already exactly right
    if $SUDO grep -qE "^#*[[:space:]]*$1([[:space:]]|\$)" "$cfg"; then
      $SUDO sed -i "s|^#*[[:space:]]*$1.*|$2|" "$cfg" # rewrite existing/commented
    else
      printf '%s\n' "$2" | $SUDO tee -a "$cfg" >/dev/null   # keyword absent: append
    fi
    applied=1
  }
  ensure_directive PasswordAuthentication      'PasswordAuthentication no'
  ensure_directive KbdInteractiveAuthentication 'KbdInteractiveAuthentication no'
  ensure_directive PermitRootLogin              'PermitRootLogin prohibit-password'
  if [ "$applied" -eq 1 ]; then
    log "Hardening sshd (edited $cfg)"
    $SUDO "$SSHD_BIN" -t 2>/dev/null \
      || { warn "sshd -t failed after edit — NOT reloading; review $cfg"; applied=0; reverted=1; }
  fi
fi

if [ "$applied" -eq 1 ]; then
  # reload (not restart) is enough for AUTH-policy changes (the only thing we
  # touch) and won't drop your current session. This holds even under Ubuntu's
  # ssh.socket activation, since per-connection sshd re-reads config on each new
  # login; a Port/ListenAddress change would NOT be picked up this way, but we
  # change neither. Unit is `ssh` on Debian/Ubuntu (not `sshd`).
  $SUDO systemctl reload ssh >/dev/null 2>&1 || $SUDO systemctl reload sshd >/dev/null 2>&1 || true
  ok "SSH hardened (key-only login; password & root-password logins disabled)"
elif [ "$reverted" -eq 1 ]; then
  warn "SSH hardening NOT applied — config test failed; password login still enabled"
else
  skip "SSH hardening (already key-only)"
fi
