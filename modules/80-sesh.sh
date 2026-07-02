#!/usr/bin/env bash
# 80-sesh.sh — sesh (smart tmux session manager) + a minimal per-task workflow.
#
# sesh gives a fuzzy "attach-or-create" picker over your tmux sessions and
# project directories, so each task on the box is one named tmux session you can
# jump straight back into after a disconnect. Isolation between parallel tasks is
# Claude's job (`claude -w`), not the session manager's.
#
#   fzf      the picker UI                                    (apt)
#   zoxide   directory tracker sesh uses to discover projects (official installer)
#   sesh     the session manager itself          (go install, else prebuilt binary)
#
# Network installers (zoxide, sesh) soft-fail so a transient CDN hiccup never
# aborts the run — re-run to retry. Idempotent throughout: existing tools are
# skipped and config blocks are added only once (guarded by a marker).
[ -n "${_VPS_COMMON_LOADED:-}" ] || { echo "run via setup.sh" >&2; exit 1; }

# --- fzf (the picker) ------------------------------------------------------
if have fzf; then
  skip "fzf"
else
  log "Installing fzf via apt"
  apt_get update -y
  apt_get install -y fzf
  ok "fzf installed"
fi

# --- zoxide (official installer; lands in ~/.local/bin) --------------------
# Check the install path too: ~/.local/bin may not be on PATH in this shell yet,
# so `have` alone would reinstall every run.
if have zoxide || [ -x "$HOME/.local/bin/zoxide" ]; then
  skip "zoxide"
else
  log "Installing zoxide"
  if curl -sSfL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | sh; then
    ok "zoxide installed"
  else
    warn "zoxide install failed (transient?) — skipping; re-run later"
  fi
fi

# --- sesh (prefer `go install`; else a prebuilt release for this arch) -----
# Match on the install paths too (~/go/bin, /usr/local/bin) since neither is
# guaranteed on PATH in this shell — otherwise a re-run reinstalls.
if have sesh || [ -x "$HOME/go/bin/sesh" ] || [ -x /usr/local/bin/sesh ]; then
  skip "sesh"
elif have go; then
  log "Installing sesh via go install"
  if go install github.com/joshmedeski/sesh/v2@latest; then
    ok "sesh installed (go)"
  else
    warn "sesh 'go install' failed — skipping; re-run later"
  fi
else
  log "Installing sesh from a prebuilt release (no Go toolchain found)"
  case "$(uname -m)" in
    x86_64|amd64)  sesh_arch='amd64|x86_64' ;;
    aarch64|arm64) sesh_arch='arm64|aarch64' ;;
    *)             sesh_arch='' ;;
  esac
  if [ -z "$sesh_arch" ]; then
    warn "sesh: no prebuilt for arch $(uname -m) — install Go and re-run"
  else
    sesh_url="$(curl -fsSL https://api.github.com/repos/joshmedeski/sesh/releases/latest \
                | grep -oiE 'https://[^"]+linux[^"]*\.tar\.gz' \
                | grep -iE "$sesh_arch" | head -1 || true)"
    if [ -n "$sesh_url" ] \
       && curl -fsSL "$sesh_url" -o /tmp/sesh.tgz \
       && tar -xzf /tmp/sesh.tgz -C /tmp sesh; then
      $SUDO install -m 0755 /tmp/sesh /usr/local/bin/sesh
      rm -f /tmp/sesh.tgz /tmp/sesh
      ok "sesh installed (release binary)"
    else
      warn "sesh release download failed — skipping; re-run later"
    fi
  fi
fi

# --- shell wiring (bash): PATH + zoxide ------------------------------------
# Guarded append: added once, so the user's own .bashrc edits are preserved.
bashrc="$HOME/.bashrc"
if grep -qs 'vps-setup:sesh' "$bashrc"; then
  skip "bashrc sesh block"
else
  log "Adding sesh/zoxide block to $bashrc"
  cat >> "$bashrc" <<'EOF'

# --- vps-setup:sesh ---
export PATH="$HOME/.local/bin:$HOME/go/bin:$PATH"
command -v zoxide >/dev/null 2>&1 && eval "$(zoxide init bash)"
# --- end vps-setup:sesh ---
EOF
  ok "bashrc updated"
fi

# --- tmux wiring: don't exit on session close + a prefix+T picker ----------
# Single-quoted heredoc: the $(...) in the binding must land in tmux.conf
# literally (tmux evaluates it at keypress, not the shell now).
tmuxconf="$HOME/.tmux.conf"
if grep -qs 'vps-setup:sesh' "$tmuxconf" 2>/dev/null; then
  skip "tmux.conf sesh block"
else
  log "Adding sesh block to $tmuxconf"
  cat >> "$tmuxconf" <<'EOF'

# --- vps-setup:sesh ---
set -g detach-on-destroy off   # closing a session drops to another, not out of tmux
# prefix + T : sesh session picker (attach or create)
bind-key T display-popup -E -w 80% -h 70% "sesh connect \"$(sesh list | fzf --no-sort --prompt 'sesh ' --preview 'sesh preview {}' --preview-window 'right:55%')\""
# --- end vps-setup:sesh ---
EOF
  ok "tmux.conf updated"
fi
