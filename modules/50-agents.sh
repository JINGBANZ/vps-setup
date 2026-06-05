#!/usr/bin/env bash
# 50-agents.sh — the AI coding agents: Claude Code and Codex CLI.
[ -n "${_VPS_COMMON_LOADED:-}" ] || { echo "run via setup.sh" >&2; exit 1; }

# --- Claude Code (official native installer) -------------------------------
if have claude || [ -x "$HOME/.local/bin/claude" ]; then
  skip "Claude Code"
else
  log "Installing Claude Code"
  curl -fsSL https://claude.ai/install.sh | bash
  ok "Claude Code installed — run 'claude' to sign in"
fi

# --- Codex CLI (official installer) ----------------------------------------
if have codex; then
  skip "codex"
else
  log "Installing Codex CLI"
  curl -fsSL https://chatgpt.com/codex/install.sh | sh
  ok "codex installed — run 'codex' to sign in"
fi
