#!/usr/bin/env bash
# 80-tmux.sh — a `t` shell shortcut for a per-task tmux workflow.
#
#   t [name]   attach the named session if it exists, else create it in
#              $WORKSPACE_DIR (bare `t` uses "main"). Works from a bare shell
#              (drops you into tmux) or from inside tmux (switches to it).
#
# Switch between sessions with the built-in prefix + s — no config needed.
#
# The target directory is $WORKSPACE_DIR (default /workspace; override via env,
# e.g. WORKSPACE_DIR=/srv/code ./setup.sh).
#
# Idempotent AND self-updating: the block in ~/.bashrc is managed between markers.
# A re-run refreshes it when the content differs (e.g. after changing
# WORKSPACE_DIR) and leaves it untouched when it already matches — the user's own
# .bashrc content outside the markers is always preserved.
[ -n "${_VPS_COMMON_LOADED:-}" ] || { echo "run via setup.sh" >&2; exit 1; }

bashrc="$HOME/.bashrc"

# Desired block. Unquoted heredoc so $WORKSPACE_DIR is baked in now; the function's
# own runtime variables ($1, $n, $TMUX) are escaped so they stay literal.
desired="$(cat <<EOF
# --- vps-setup:tmux ---
# t [name] — attach or create a $WORKSPACE_DIR tmux session (default: main)
t() {
  local n=\${1:-main}
  tmux has-session -t "=\$n" 2>/dev/null || tmux new-session -ds "\$n" -c $WORKSPACE_DIR
  [ -n "\$TMUX" ] && tmux switch-client -t "\$n" || tmux attach -t "\$n"
}
# --- end vps-setup:tmux ---
EOF
)"

# What's currently installed between the markers (empty if none).
current="$(sed -n '/^# --- vps-setup:tmux ---$/,/^# --- end vps-setup:tmux ---$/p' "$bashrc" 2>/dev/null || true)"

if [ "$current" = "$desired" ]; then
  skip "t() shortcut (up to date)"
elif [ -n "$current" ]; then
  # Replace ONLY the marked block, in place. Every line outside the two markers
  # is copied through verbatim and stays exactly where it was.
  log "Updating t() shortcut in $bashrc"
  blockfile="$(mktemp)"; printf '%s\n' "$desired" > "$blockfile"
  tmp="$(mktemp)"
  awk -v bf="$blockfile" '
    /^# --- vps-setup:tmux ---$/      { while ((getline line < bf) > 0) print line; close(bf); inblk=1; next }
    inblk && /^# --- end vps-setup:tmux ---$/ { inblk=0; next }
    !inblk                            { print }
  ' "$bashrc" > "$tmp" && mv "$tmp" "$bashrc"
  rm -f "$blockfile"
  ok "bashrc updated (t() → $WORKSPACE_DIR)"
else
  log "Adding t() shortcut to $bashrc"
  printf '\n%s\n' "$desired" >> "$bashrc"
  ok "bashrc updated (t() → $WORKSPACE_DIR)"
fi
