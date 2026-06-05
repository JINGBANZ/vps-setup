#!/usr/bin/env bash
#
# setup.sh — Set up my standard toolset on a fresh Linux (Debian/Ubuntu) VPS.
#
# Tools (and the OFFICIAL install method each follows):
#   git, curl, unzip, tmux, mosh, ufw  -> apt          (official on Debian/Ubuntu)
#   gh (GitHub CLI)                    -> cli.github.com signed apt repo
#   Tailscale                          -> tailscale.com/install.sh
#   nvm                                -> nvm-sh versioned install.sh
#   Node.js (LTS)                      -> nvm install --lts
#   Bun                                -> bun.com/install
#   Claude Code                        -> claude.ai/install.sh   (native installer)
#   Codex CLI                          -> chatgpt.com/codex/install.sh
#
# Every step checks whether the tool already exists and SKIPS it if so,
# so the script is safe to run repeatedly.
#
# Usage:
#   chmod +x setup.sh && ./setup.sh
#
set -euo pipefail

NVM_VERSION="v0.40.5"   # pin to a known-good nvm release (latest as of writing)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
skip() { printf '\033[1;33m--\033[0m %s \033[1;33m(already installed, skipping)\033[0m\n' "$*"; }
ok()   { printf '\033[1;32mok\033[0m %s\n' "$*"; }

# Use sudo only when we're not already root.
if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

have() { command -v "$1" >/dev/null 2>&1; }

if ! have apt-get; then
  echo "This script targets Debian/Ubuntu (apt). Adapt it for your distro." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 1. APT tools: git, curl, unzip, tmux, mosh, ufw
#    (unzip must exist before Bun is installed.)
# ---------------------------------------------------------------------------
APT_PKGS=(git curl unzip tmux mosh ufw)

missing=()
for pkg in "${APT_PKGS[@]}"; do
  if have "$pkg"; then
    skip "$pkg"
  else
    missing+=("$pkg")
  fi
done

if [ "${#missing[@]}" -gt 0 ]; then
  log "Installing via apt: ${missing[*]}"
  export DEBIAN_FRONTEND=noninteractive
  $SUDO apt-get update -y
  $SUDO apt-get install -y "${missing[@]}"
  ok "apt packages installed"
fi

# ---------------------------------------------------------------------------
# 2. gh / GitHub CLI  (official: cli.github.com signed apt repo)
# ---------------------------------------------------------------------------
if have gh; then
  skip "gh ($(gh --version 2>/dev/null | head -1))"
else
  log "Installing GitHub CLI (gh)"
  $SUDO install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | $SUDO tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
  $SUDO chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | $SUDO tee /etc/apt/sources.list.d/github-cli.list >/dev/null
  $SUDO apt-get update -y
  $SUDO apt-get install -y gh
  ok "gh installed — run 'gh auth login' to authenticate"
fi

# ---------------------------------------------------------------------------
# 3. Tailscale  (official: https://tailscale.com/install.sh)
# ---------------------------------------------------------------------------
if have tailscale; then
  skip "tailscale ($(tailscale version 2>/dev/null | head -1))"
else
  log "Installing Tailscale"
  curl -fsSL https://tailscale.com/install.sh | $SUDO sh
  ok "tailscale installed — run 'sudo tailscale up' to authenticate"
fi

# ---------------------------------------------------------------------------
# 4. nvm  (official: nvm-sh versioned installer)
# ---------------------------------------------------------------------------
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
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

# ---------------------------------------------------------------------------
# 5. Node.js (LTS)  (official via nvm: nvm install --lts)
# ---------------------------------------------------------------------------
if have nvm && nvm which current >/dev/null 2>&1; then
  skip "Node.js ($(node --version 2>/dev/null))"
elif have node; then
  skip "Node.js ($(node --version)) — found outside nvm"
else
  log "Installing Node.js LTS via nvm"
  nvm install --lts
  nvm alias default 'lts/*'
  ok "Node.js installed ($(node --version 2>/dev/null))"
fi

# ---------------------------------------------------------------------------
# 6. Bun  (official: https://bun.com/install — needs unzip, installed above)
# ---------------------------------------------------------------------------
if have bun || [ -x "$HOME/.bun/bin/bun" ]; then
  skip "bun"
else
  log "Installing Bun"
  curl -fsSL https://bun.com/install | bash
  ok "bun installed"
fi

# ---------------------------------------------------------------------------
# 7. Claude Code  (official native installer: https://claude.ai/install.sh)
# ---------------------------------------------------------------------------
if have claude || [ -x "$HOME/.local/bin/claude" ]; then
  skip "Claude Code"
else
  log "Installing Claude Code"
  curl -fsSL https://claude.ai/install.sh | bash
  ok "Claude Code installed — run 'claude' to sign in"
fi

# ---------------------------------------------------------------------------
# 8. Codex CLI  (official: https://chatgpt.com/codex/install.sh)
# ---------------------------------------------------------------------------
if have codex; then
  skip "codex"
else
  log "Installing Codex CLI"
  curl -fsSL https://chatgpt.com/codex/install.sh | sh
  ok "codex installed — run 'codex' to sign in"
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
log "Setup complete."
cat <<'EOF'

Open a new shell (or `source ~/.bashrc`) so PATH changes take effect.

Manual auth steps, as needed:
  - tailscale:  sudo tailscale up
  - gh:         gh auth login
  - claude:     claude     (sign in on first run)
  - codex:      codex       (sign in with ChatGPT)
EOF
