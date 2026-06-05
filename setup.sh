#!/usr/bin/env bash
#
# setup.sh — Set up a standard toolset on a fresh Linux (Debian/Ubuntu) VPS.
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
# It then applies a SECURITY layer (always, not optional):
#   ufw firewall (default-deny inbound, SSH/mosh/Tailscale allowed)
#   fail2ban (bans brute-force SSH attempts)
#   unattended-upgrades (automatic security patches)
#   SSH hardening (key-only auth) — auto-skipped if no SSH key is present
#
# Every step checks whether the tool already exists and SKIPS it if so,
# so the script is safe to run repeatedly. All output is also written to
# a logfile (default: ~/vps-setup.log).
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
warn() { printf '\033[1;31m!!\033[0m %s\n' "$*"; }

# Use sudo only when we're not already root.
if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

have() { command -v "$1" >/dev/null 2>&1; }

# The user we hardened SSH for / installed user tools as. When invoked with
# sudo this is the original login user, not root.
TARGET_USER="${SUDO_USER:-$(id -un)}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[ -n "$TARGET_HOME" ] || TARGET_HOME="$HOME"

if ! have apt-get; then
  echo "This script targets Debian/Ubuntu (apt). Adapt it for your distro." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Logging: mirror everything to a logfile so a failed run is debuggable.
# `>(tee -a ...)` is bash process substitution; `exec` points our stdout/stderr
# at it for the rest of the run, so output is shown live AND appended to the log.
# ---------------------------------------------------------------------------
LOGFILE="${LOGFILE:-$TARGET_HOME/vps-setup.log}"
exec > >(tee -a "$LOGFILE") 2>&1
log "Logging to $LOGFILE ($(date -u '+%Y-%m-%dT%H:%M:%SZ'))"

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
  $SUDO mkdir -p -m 755 /etc/apt/sources.list.d
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
# Resolve NVM_DIR the same way nvm's official profile snippet does (honors
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

# ---------------------------------------------------------------------------
# 5. Node.js (LTS)  (official via nvm: nvm install --latest-npm 'lts/*')
# ---------------------------------------------------------------------------
if have nvm && nvm which current >/dev/null 2>&1; then
  skip "Node.js ($(node --version 2>/dev/null))"
elif have node; then
  skip "Node.js ($(node --version)) — found outside nvm"
else
  log "Installing Node.js LTS via nvm"
  nvm install --latest-npm 'lts/*'   # official nvm recipe for latest LTS + npm
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

# ===========================================================================
# SECURITY HARDENING (always runs — security is not optional)
# ===========================================================================

# ---------------------------------------------------------------------------
# 9. Firewall (ufw): default-deny inbound, but allow SSH/mosh/Tailscale FIRST
#    so enabling it can never lock us out.
# ---------------------------------------------------------------------------
SSH_PORT="${SSH_PORT:-22}"
log "Configuring ufw firewall"
$SUDO ufw allow "${SSH_PORT}/tcp"            >/dev/null   # SSH — open before enabling
$SUDO ufw allow 60000:61000/udp              >/dev/null   # mosh
$SUDO ufw allow in on tailscale0             >/dev/null 2>&1 || true  # trust the tailnet
$SUDO ufw default deny incoming              >/dev/null
$SUDO ufw default allow outgoing             >/dev/null
$SUDO ufw --force enable                      >/dev/null
ok "ufw enabled (allow SSH ${SSH_PORT}/tcp, mosh, tailscale0; deny other inbound)"

# ---------------------------------------------------------------------------
# 10. fail2ban: ban IPs after repeated failed SSH logins
# ---------------------------------------------------------------------------
if ! have fail2ban-client; then
  log "Installing fail2ban"
  $SUDO apt-get install -y fail2ban >/dev/null
fi
log "Configuring fail2ban sshd jail"
$SUDO tee /etc/fail2ban/jail.local >/dev/null <<EOF
# Managed by vps-setup/setup.sh
[sshd]
enabled  = true
backend  = systemd
port     = ${SSH_PORT}
maxretry = 3
findtime = 1h
bantime  = 24h
EOF
$SUDO systemctl enable --now fail2ban >/dev/null 2>&1 || true
$SUDO systemctl restart fail2ban       >/dev/null 2>&1 || true
ok "fail2ban active (3 fails/hour -> 24h ban)"

# ---------------------------------------------------------------------------
# 11. Automatic security updates (unattended-upgrades)
# ---------------------------------------------------------------------------
if ! dpkg -s unattended-upgrades >/dev/null 2>&1; then
  log "Installing unattended-upgrades"
  $SUDO apt-get install -y unattended-upgrades >/dev/null
fi
# Enable the daily apt timers that drive unattended security upgrades.
$SUDO tee /etc/apt/apt.conf.d/20auto-upgrades >/dev/null <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
$SUDO systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
ok "unattended-upgrades enabled (security patches install automatically)"

# ---------------------------------------------------------------------------
# 12. SSH hardening: key-only auth, root login by key only.
#     GUARDED: skipped if no SSH key is present, so we never lock you out.
#     Validated with `sshd -t` before reload; reverted if the config is bad.
# ---------------------------------------------------------------------------
log "Hardening SSH (key-only auth)"
key_found=0
for kf in /root/.ssh/authorized_keys "$TARGET_HOME/.ssh/authorized_keys"; do
  [ -s "$kf" ] && key_found=1
done

if [ "$key_found" -ne 1 ]; then
  warn "No SSH authorized_keys found for root or $TARGET_USER — SKIPPING SSH hardening"
  warn "to avoid locking you out. Add your key (ssh-copy-id) and re-run to enable"
  warn "key-only SSH."
else
  $SUDO install -d -m 0755 /etc/ssh/sshd_config.d
  $SUDO tee /etc/ssh/sshd_config.d/99-hardening.conf >/dev/null <<'EOF'
# Managed by vps-setup/setup.sh — key-only SSH.
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF
  if $SUDO sshd -t; then
    $SUDO systemctl reload ssh  >/dev/null 2>&1 \
      || $SUDO systemctl reload sshd >/dev/null 2>&1 || true
    ok "SSH hardened (password auth disabled; root key-only)"
  else
    warn "sshd config test failed — reverting hardening, leaving SSH unchanged."
    $SUDO rm -f /etc/ssh/sshd_config.d/99-hardening.conf
  fi
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

Security applied: ufw firewall, fail2ban, automatic security updates, and
key-only SSH. If SSH hardening was skipped, add your public key
(ssh-copy-id user@host) and re-run to enable it.
EOF
