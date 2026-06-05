#!/usr/bin/env bash
# 40-node-bun.sh — JS/TS runtimes: nvm + Node.js (LTS), and Bun.
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
if have nvm && nvm which current >/dev/null 2>&1; then
  skip "Node.js ($(node --version 2>/dev/null))"
elif have node; then
  skip "Node.js ($(node --version)) — found outside nvm"
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
  curl -fsSL https://bun.com/install | bash
  ok "bun installed"
fi
