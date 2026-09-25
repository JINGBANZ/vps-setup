#!/usr/bin/env bash
# 35-disk-guard.sh — keep the root disk from filling up and taking the box down.
#
# A full root disk stops more than builds: sshd, journald and tmux start failing,
# which on a remote box can look like a crash. Parallel agents each building in
# their own worktree reach that point quickly. Two parts:
#   * cap the systemd journal, which otherwise grows to a percentage of the disk;
#   * a timer that warns (journal + every attached tmux client) above
#     DISK_GUARD_WARN_PCT, and above DISK_GUARD_CLEAN_PCT prunes the Docker
#     build cache and dangling images, which are always safe to rebuild.
# It deliberately deletes nothing else: build outputs and volumes may belong to
# a session that is using them right now, so freeing those stays a human call.
[ -n "${_VPS_COMMON_LOADED:-}" ] || { echo "run via setup.sh" >&2; exit 1; }

DISK_GUARD_WARN_PCT="${DISK_GUARD_WARN_PCT:-80}"
DISK_GUARD_CLEAN_PCT="${DISK_GUARD_CLEAN_PCT:-90}"

# A threshold the guard cannot compare would silently switch it off, so a bad
# value falls back to the defaults instead of being installed.
_pct_ok() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 100 ]; }
if ! _pct_ok "$DISK_GUARD_WARN_PCT" || ! _pct_ok "$DISK_GUARD_CLEAN_PCT" \
   || [ "$DISK_GUARD_WARN_PCT" -gt "$DISK_GUARD_CLEAN_PCT" ]; then
  warn "disk guard: thresholds must be 1-100 with warn <= clean; using 80/90"
  DISK_GUARD_WARN_PCT=80
  DISK_GUARD_CLEAN_PCT=90
fi

# RuntimeMaxUse covers hosts whose journal is volatile (/run/log/journal).
if write_config /etc/systemd/journald.conf.d/50-vps-setup.conf <<'EOF'
# Managed by vps-setup/setup.sh
[Journal]
SystemMaxUse=200M
RuntimeMaxUse=200M
EOF
then
  $SUDO systemctl restart systemd-journald >/dev/null 2>&1 || true
  ok "journal capped at 200M"
else
  skip "journal cap (already configured)"
fi

_guard_changed=0
if write_config /usr/local/sbin/disk-guard 0755 <<'EOF'
#!/usr/bin/env bash
# Managed by vps-setup/setup.sh — see modules/35-disk-guard.sh.
set -uo pipefail

WARN_PCT="${DISK_GUARD_WARN_PCT:-80}"
CLEAN_PCT="${DISK_GUARD_CLEAN_PCT:-90}"
NOTIFY_USER="${DISK_GUARD_NOTIFY_USER:-root}"
# One tmux warning per hour is enough to be seen without drowning the status
# line; the journal still records every check that finds the disk too full.
STAMP=/run/disk-guard.warned

used_pct() { df --output=pcent / | tail -1 | tr -dc '0-9'; }

# tmux keeps one server per user, so root's and the login user's are separate.
# A timer has no "current" client, so address each attached one by name.
tmux_warn() {
  local user="$1" message="$2"
  runuser -u "$user" -- tmux list-clients -F '#{client_name}' 2>/dev/null \
    | while IFS= read -r client; do
        runuser -u "$user" -- tmux display-message -c "$client" -d 15000 "$message" 2>/dev/null || true
      done
}

pct="$(used_pct)"
[ "$pct" -ge "$WARN_PCT" ] || exit 0

message="disk-guard: / is ${pct}% full."
if [ "$pct" -ge "$CLEAN_PCT" ] && command -v docker >/dev/null 2>&1; then
  docker builder prune -af >/dev/null 2>&1 || true
  docker image prune -f >/dev/null 2>&1 || true
  after="$(used_pct)"
  message="disk-guard: / was ${pct}% full; pruned Docker build cache and dangling images, now ${after}%."
  pct="$after"
fi
logger -p user.warning -t disk-guard "$message"

if [ "$pct" -ge "$WARN_PCT" ] && [ -z "$(find "$STAMP" -mmin -60 2>/dev/null)" ] \
   && command -v tmux >/dev/null 2>&1; then
  message="$message Free space before builds fail: du -xh --max-depth=3 / | sort -rh | head"
  tmux_warn root "$message"
  [ "$NOTIFY_USER" = root ] || tmux_warn "$NOTIFY_USER" "$message"
  touch "$STAMP"
fi
EOF
then _guard_changed=1; fi

if write_config /etc/systemd/system/disk-guard.service <<EOF
# Managed by vps-setup/setup.sh
[Unit]
Description=Warn before the root disk fills, and prune rebuildable caches

[Service]
Type=oneshot
Environment=DISK_GUARD_WARN_PCT=${DISK_GUARD_WARN_PCT}
Environment=DISK_GUARD_CLEAN_PCT=${DISK_GUARD_CLEAN_PCT}
Environment=DISK_GUARD_NOTIFY_USER=${TARGET_USER}
ExecStart=/usr/local/sbin/disk-guard
Nice=10
EOF
then _guard_changed=1; fi

if write_config /etc/systemd/system/disk-guard.timer <<'EOF'
# Managed by vps-setup/setup.sh
[Unit]
Description=Check root disk usage every 10 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=10min

[Install]
WantedBy=timers.target
EOF
then _guard_changed=1; fi

# Activation runs on every setup, not only when a file changed, so a rerun
# repairs a timer that failed to start the first time.
[ "$_guard_changed" -eq 0 ] || $SUDO systemctl daemon-reload
if $SUDO systemctl enable --now disk-guard.timer >/dev/null 2>&1 \
   && systemctl is-active --quiet disk-guard.timer; then
  if [ "$_guard_changed" -eq 1 ]; then
    ok "disk guard: warns at ${DISK_GUARD_WARN_PCT}%, prunes Docker caches at ${DISK_GUARD_CLEAN_PCT}%"
  else
    skip "disk guard (already configured)"
  fi
else
  warn "disk guard: timer failed to start — check 'systemctl status disk-guard.timer'"
fi
