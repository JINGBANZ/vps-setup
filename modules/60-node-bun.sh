#!/usr/bin/env bash
# 60-node-bun.sh — JS/TS runtimes: nvm + Node.js (LTS), and Bun.
[ -n "${_VPS_COMMON_LOADED:-}" ] || { echo "run via setup.sh" >&2; exit 1; }

# --- nvm (official versioned installer) -----------------------------------
# Resolve NVM_DIR the way nvm's official profile snippet does (honors
# XDG_CONFIG_HOME, falling back to ~/.nvm).
export NVM_DIR="${NVM_DIR:-$([ -z "${XDG_CONFIG_HOME-}" ] && printf %s "${HOME}/.nvm" || printf %s "${XDG_CONFIG_HOME}/nvm")}"
if [ -s "$NVM_DIR/nvm.sh" ]; then
  skip "nvm"
else
  log "Installing nvm $NVM_VERSION"
  curl -o- "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" | bash
  ok "nvm installed"
fi

# Load nvm into the current shell so we can use it below.
# shellcheck disable=SC1091
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"

# --- Node.js LTS (official nvm recipe) ------------------------------------
# Sourcing nvm.sh doesn't auto-select a version, so activate the default first.
# Then a re-run reliably detects an existing install and skips (instead of
# redundantly re-running `nvm install`). No-op/harmless if no default is set yet.
nvm use default >/dev/null 2>&1 || true
if have node; then
  skip "Node.js ($(node --version 2>/dev/null))"
else
  log "Installing Node.js LTS via nvm"
  nvm install --latest-npm 'lts/*'
  nvm alias default 'lts/*'
  ok "Node.js installed ($(node --version 2>/dev/null))"
fi

# --- Bun (official installer; needs unzip from 10-apt-tools.sh) ------------
if have bun || [ -x "$HOME/.bun/bin/bun" ]; then
  skip "bun"
else
  log "Installing Bun"
  # Optional tool: a transient download failure shouldn't abort the whole run.
  if curl -fsSL https://bun.com/install | bash; then
    ok "bun installed"
  else
    warn "Bun install failed (transient network/CDN?) — skipping; re-run later"
  fi
fi
