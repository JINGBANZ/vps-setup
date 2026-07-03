#!/usr/bin/env bash
# 80-tmux.sh — a `t` shell shortcut for a per-task tmux workflow under /workplace.
#
#   t [name]   attach the named session if it exists, else create it in
#              /workplace (bare `t` uses "main"). Works from a bare shell (drops
#              you into tmux) or from inside tmux (switches to it).
#
# Switch between sessions with the built-in prefix + s — no config needed.
#
# Idempotent: the block is appended to ~/.bashrc once, guarded by a marker, so
# re-runs and the user's own edits are both preserved.
[ -n "${_VPS_COMMON_LOADED:-}" ] || { echo "run via setup.sh" >&2; exit 1; }

bashrc="$HOME/.bashrc"
if grep -qs 'vps-setup:tmux' "$bashrc" 2>/dev/null; then
  skip "bashrc t() shortcut"
else
  log "Adding t() shortcut to $bashrc"
  cat >> "$bashrc" <<'EOF'

# --- vps-setup:tmux ---
# t [name] — attach or create a /workplace tmux session (default: main)
t() {
  local n=${1:-main}
  tmux has-session -t "=$n" 2>/dev/null || tmux new-session -ds "$n" -c /workplace
  [ -n "$TMUX" ] && tmux switch-client -t "$n" || tmux attach -t "$n"
}
# --- end vps-setup:tmux ---
EOF
  ok "bashrc updated"
fi
