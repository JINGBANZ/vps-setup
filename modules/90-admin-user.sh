#!/usr/bin/env bash
# 90-admin-user.sh — create a non-root sudo user (least-privilege login).
#
# Runs only when ADMIN_USER is set (e.g. ADMIN_USER=deploy ./setup.sh).
# Mostly automated: the only thing the script can't invent is your SSH public
# key, which it sources in priority order:
#   1. $ADMIN_SSH_KEY (explicit), else
#   2. root's existing ~/.ssh/authorized_keys (the usual key-based-root case).
[ -n "${_VPS_COMMON_LOADED:-}" ] || { echo "run via setup.sh" >&2; exit 1; }

if [ -z "$ADMIN_USER" ]; then
  skip "admin user (set ADMIN_USER=name to create a non-root sudo user)"
  return 0 2>/dev/null || exit 0
fi

# --- create the user + grant sudo -----------------------------------------
if id "$ADMIN_USER" >/dev/null 2>&1; then
  skip "admin user '$ADMIN_USER' (exists)"
else
  log "Creating admin user '$ADMIN_USER'"
  # --disabled-password: no password set => key-only login. sudo access is
  # handled below (password or NOPASSWD).
  $SUDO adduser --disabled-password --gecos "" "$ADMIN_USER"
fi
$SUDO usermod -aG sudo "$ADMIN_USER"

# --- sudo policy -----------------------------------------------------------
if [ "$ADMIN_NOPASSWD_SUDO" = "1" ]; then
  echo "$ADMIN_USER ALL=(ALL) NOPASSWD:ALL" \
    | $SUDO tee "/etc/sudoers.d/90-$ADMIN_USER" >/dev/null
  $SUDO chmod 0440 "/etc/sudoers.d/90-$ADMIN_USER"
  ok "passwordless sudo granted to '$ADMIN_USER'"
else
  warn "'$ADMIN_USER' has no password yet — set one so sudo works:"
  warn "    sudo passwd $ADMIN_USER"
  warn "  (or re-run with ADMIN_NOPASSWD_SUDO=1 for passwordless sudo)"
fi

# --- install the SSH key so you can log in as the new user ----------------
admin_home="$(getent passwd "$ADMIN_USER" | cut -d: -f6)"
key=""
if [ -n "$ADMIN_SSH_KEY" ]; then
  key="$ADMIN_SSH_KEY"
elif [ -s /root/.ssh/authorized_keys ]; then
  key="$(cat /root/.ssh/authorized_keys)"
fi

if [ -n "$key" ]; then
  $SUDO install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_USER" "$admin_home/.ssh"
  printf '%s\n' "$key" | $SUDO tee "$admin_home/.ssh/authorized_keys" >/dev/null
  $SUDO chown "$ADMIN_USER:$ADMIN_USER" "$admin_home/.ssh/authorized_keys"
  $SUDO chmod 600 "$admin_home/.ssh/authorized_keys"
  ok "admin user '$ADMIN_USER' ready (sudo group + SSH key installed)"
  warn "VERIFY from your laptop BEFORE trusting this:  ssh $ADMIN_USER@<host>"
  warn "Confirm login + 'sudo -v' work before disabling root (DISABLE_ROOT_LOGIN=1)."
else
  warn "No SSH key available for '$ADMIN_USER' (set ADMIN_SSH_KEY, or add root's key)."
  warn "From your laptop:  ssh-copy-id $ADMIN_USER@<host>"
fi
