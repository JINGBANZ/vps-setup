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

if [ "${INSTALL_CLAUDE:-1}" = 1 ]; then
# --- Claude Code (official native installer) -------------------------------
if { have claude && claude --version >/dev/null 2>&1; } ||
   { [ -x "$HOME/.local/bin/claude" ] && "$HOME/.local/bin/claude" --version >/dev/null 2>&1; }; then
  skip "Claude Code"
else
  log "Installing Claude Code"
  if curl -fsSL https://claude.ai/install.sh | bash; then
    ok "Claude Code installed"
  else
    warn "Claude Code install failed; check output above and retry"
  fi
fi

fi # INSTALL_CLAUDE

if [ "${INSTALL_CODEX:-1}" = 1 ]; then
# --- Codex CLI (official installer; installs to ~/.local/bin/codex) ---------
if { have codex && codex --version >/dev/null 2>&1; } ||
   { [ -x "$HOME/.local/bin/codex" ] && "$HOME/.local/bin/codex" --version >/dev/null 2>&1; }; then
  skip "codex"
else
  log "Installing Codex"
  if curl -fsSL https://chatgpt.com/codex/install.sh | sh; then
    ok "Codex installed"
  else
    warn "Codex install failed; check output above and retry"
  fi
fi
fi # INSTALL_CODEX

