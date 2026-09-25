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
# One warning per hour is enough to be seen without drowning the tmux status line.
STAMP=/run/disk-guard.warned

used_pct() { df --output=pcent / | tail -1 | tr -dc '0-9'; }

notify() {
  logger -p user.warning -t disk-guard "$1"
  command -v tmux >/dev/null 2>&1 || return 0
  # A timer has no "current" tmux client, so address each attached one by name.
  tmux list-clients -F '#{client_name}' 2>/dev/null | while IFS= read -r client; do
    tmux display-message -c "$client" -d 15000 "$1" 2>/dev/null || true
  done
}

pct="$(used_pct)"
[ "$pct" -ge "$WARN_PCT" ] || exit 0

if [ "$pct" -ge "$CLEAN_PCT" ] && command -v docker >/dev/null 2>&1; then
  docker builder prune -af >/dev/null 2>&1 || true
  docker image prune -f >/dev/null 2>&1 || true
  after="$(used_pct)"
  notify "disk-guard: / was ${pct}% full; pruned Docker build cache and dangling images, now ${after}%"
  pct="$after"
fi

if [ "$pct" -ge "$WARN_PCT" ] && [ -z "$(find "$STAMP" -mmin -60 2>/dev/null)" ]; then
  notify "disk-guard: / is ${pct}% full. Free space before builds fail: du -xh --max-depth=3 / | sort -rh | head"
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

if [ "$_guard_changed" -eq 1 ]; then
  $SUDO systemctl daemon-reload
  $SUDO systemctl enable --now disk-guard.timer >/dev/null 2>&1 || true
  ok "disk guard: warns at ${DISK_GUARD_WARN_PCT}%, prunes Docker caches at ${DISK_GUARD_CLEAN_PCT}%"
else
  skip "disk guard (already configured)"
fi
