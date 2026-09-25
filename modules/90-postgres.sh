#!/usr/bin/env bash
# 90-postgres.sh — one shared local PostgreSQL server for development.
#
# Opt-in: does nothing unless DEV_POSTGRES=1. Parallel worktrees then share this
# one server instead of each starting its own database container; projects keep
# their test data apart by creating throwaway databases, not separate servers.
#
# Installs the distro's default major version. The server listens on its Unix
# socket only (no TCP port), so it can never collide with a project's Compose
# database on 5432, and nothing off the box can reach it. Connections use peer
# authentication — the OS user is the database role — so no password exists to
# store or leak. Connect with e.g. psql, or from a URL:
#   postgresql://$USER@%2Fvar%2Frun%2Fpostgresql/postgres
[ -n "${_VPS_COMMON_LOADED:-}" ] || { echo "run via setup.sh" >&2; exit 1; }

# Run a command as the postgres OS user (peer auth makes it the DB superuser).
# runuser covers the root path, where SUDO="" and sudo may not be installed.
_pg_do() {
  if [ -z "$SUDO" ]; then runuser -u postgres -- "$@"; else sudo -u postgres "$@"; fi
}

if [ "${DEV_POSTGRES:-}" != "1" ]; then
  skip "PostgreSQL (opt-in: set DEV_POSTGRES=1)"
else
  if ! dpkg -s postgresql >/dev/null 2>&1; then
    log "Installing PostgreSQL"
    apt_get install -y postgresql >/dev/null
  fi

  _pg_changed=0
  for _pg_conf in /etc/postgresql/*/main/conf.d; do
    [ -d "$_pg_conf" ] || continue
    if write_config "$_pg_conf/50-vps-setup.conf" <<'EOF'
# Managed by vps-setup/setup.sh — Unix socket only; see modules/90-postgres.sh.
listen_addresses = ''
EOF
    then _pg_changed=1; fi
  done
  $SUDO systemctl enable postgresql >/dev/null 2>&1 || true
  if [ "$_pg_changed" -eq 1 ]; then
    $SUDO systemctl restart postgresql
  else
    $SUDO systemctl start postgresql
  fi
  ok "PostgreSQL running on its Unix socket only"

  # The login user gets a superuser role of the same name, matching the image
  # superuser that project CI and Compose databases give their tests. It is a
  # development box whose login user already holds sudo, so this grants nothing
  # the user could not take anyway.
  # A role someone created by hand is reported rather than altered: changing
  # its privileges is the owner's decision, not a provisioning side effect.
  _pg_role="$(_pg_do psql -tAc "SELECT rolsuper AND rolcanlogin FROM pg_roles WHERE rolname = '$TARGET_USER'")"
  # The superuser role is safe only because peer authentication ties it to one
  # OS user. A pre-existing cluster with a local `trust` rule would hand it to
  # every local user, so refuse rather than create it there.
  _pg_trust="$(_pg_do psql -tAc "SELECT count(*) FROM pg_hba_file_rules WHERE type = 'local' AND auth_method = 'trust'")"
  if [ "$_pg_trust" != "0" ]; then
    warn "PostgreSQL has a local 'trust' rule in pg_hba.conf — not creating a superuser role for '$TARGET_USER'"
  elif [ "$_pg_role" = "t" ]; then
    skip "PostgreSQL role '$TARGET_USER' (already exists)"
  elif [ "$_pg_role" = "f" ]; then
    warn "PostgreSQL role '$TARGET_USER' exists without LOGIN SUPERUSER — left unchanged"
  else
    _pg_do createuser --superuser "$TARGET_USER"
    ok "PostgreSQL role '$TARGET_USER' (peer authentication, superuser)"
  fi
fi
