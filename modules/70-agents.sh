#!/usr/bin/env bash
# 70-agents.sh — the AI coding agents: Claude Code and Codex CLI.
#
# These are OPTIONAL tools fetched from third-party CDNs. Their installers can
# fail transiently (e.g. a 504 from the download host) — and Codex's installer
# even crashes with "tmp: unbound variable" when its download fails. Such a
# failure must NOT abort setup.sh, or the security modules (which now run first)
# would still be safe but the run would look failed. We soft-fail each: warn and
# continue so the rest of the run completes; the user can re-run to retry.
[ -n "${_VPS_COMMON_LOADED:-}" ] || { echo "run via setup.sh" >&2; exit 1; }

# --- Claude Code (official native installer) -------------------------------
if have claude || [ -x "$HOME/.local/bin/claude" ]; then
  skip "Claude Code"
else
  log "Installing Claude Code"
  if curl -fsSL https://claude.ai/install.sh | bash; then
    ok "Claude Code installed — run 'claude' to sign in"
  else
    warn "Claude Code install failed (transient?) — skipping; re-run later"
  fi
fi

# --- Codex CLI (official installer; installs to ~/.local/bin/codex) ---------
if have codex || [ -x "$HOME/.local/bin/codex" ]; then
  skip "codex"
else
  log "Installing Codex CLI"
  if curl -fsSL https://chatgpt.com/codex/install.sh | sh; then
    ok "codex installed — run 'codex' to sign in"
  else
    warn "Codex install failed (transient?) — skipping; re-run later"
  fi
fi
