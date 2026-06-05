#!/usr/bin/env bash
# 90-admin-user.sh — optionally create a non-root sudo user (least-privilege
# login). Interactive: asks first; does nothing unless you say yes.
#
# When you opt in:
#   * username defaults to 'dev'
#   * added to the sudo group, with PASSWORDLESS sudo
#   * SSH key resolved by priority: root's authorized_keys, else you paste one
# Runs before SSH hardening (99) so the user exists before login rules change.
[ -n "${_VPS_COMMON_LOADED:-}" ] || { echo "run via setup.sh" >&2; exit 1; }

if ! ask_yes_no "Create a non-root admin user (passwordless sudo)?" "n"; then
  skip "admin user (declined)"
  return 0 2>/dev/null || exit 0
fi

admin_user="$(ask_value "   Username for the admin user:" "dev")"
admin_user="${admin_user:-dev}"

# --- create the user + grant passwordless sudo ----------------------------
if id "$admin_user" >/dev/null 2>&1; then
  skip "user '$admin_user' (exists)"
else
  log "Creating admin user '$admin_user'"
  # --disabled-password: no password => key-only login. sudo is passwordless
  # (below), so the missing password never blocks sudo.
  $SUDO adduser --disabled-password --gecos "" "$admin_user"
fi
$SUDO usermod -aG sudo "$admin_user"

echo "$admin_user ALL=(ALL) NOPASSWD:ALL" \
  | $SUDO tee "/etc/sudoers.d/90-$admin_user" >/dev/null
$SUDO chmod 0440 "/etc/sudoers.d/90-$admin_user"
ok "'$admin_user' created with passwordless sudo"

# --- install the SSH key so you can log in as the new user ----------------
key="$(get_ssh_public_key)"   # root's key, or prompts you to paste one
if [ -n "$key" ]; then
  install_authorized_key "$admin_user" "$key"
  ok "SSH key installed for '$admin_user'"
  warn "VERIFY from your laptop BEFORE logging out:  ssh $admin_user@<host>"
  warn "Confirm 'sudo -v' works too. Root stays reachable by key as a fallback."
else
  warn "No SSH key provided for '$admin_user'. Add one from your laptop with:"
  warn "    ssh-copy-id $admin_user@<host>"
fi
