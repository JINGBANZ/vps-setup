#!/usr/bin/env bash
#
# setup.sh — provision a fresh Debian/Ubuntu VPS for an AI-assisted dev workflow.
#
# This is a thin orchestrator: it sources shared helpers (lib/common.sh) and then
# runs each module in modules/ in order. Each module is self-contained and
# idempotent (checks-then-installs), so the whole script is safe to re-run.
#
#   modules/10-apt-tools.sh    git, curl, unzip, tmux, mosh, ufw   (apt)
#   modules/20-gh.sh           GitHub CLI                          (apt repo)
#   modules/30-tailscale.sh    Tailscale                          (install.sh)
#   modules/40-node-bun.sh     nvm + Node.js (LTS) + Bun
#   modules/50-agents.sh       Claude Code + Codex CLI
#   modules/60-firewall.sh     ufw (default-deny, SSH/mosh/tailscale allowed)
#   modules/70-fail2ban.sh     fail2ban sshd jail
#   modules/80-auto-updates.sh unattended-upgrades (auto security patches)
#   modules/90-admin-user.sh   non-root sudo user        (when ADMIN_USER set)
#   modules/99-ssh-harden.sh   key-only SSH              (guarded; no lockout)
#
# Usage:
#   ./setup.sh                          # tools + security
#   ADMIN_USER=deploy ./setup.sh        # also create a non-root sudo user
#   SSH_PORT=2222 ./setup.sh            # non-standard SSH port
# See README.md for all env knobs (ADMIN_SSH_KEY, ADMIN_NOPASSWD_SUDO,
# DISABLE_ROOT_LOGIN, NVM_VERSION, LOGFILE).
#
set -euo pipefail

# Resolve our own directory so the script works from any cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

require_apt

# Mirror all output to a logfile so a failed run is debuggable. `>(tee -a ...)`
# is bash process substitution; exec points our stdout/stderr at it.
LOGFILE="${LOGFILE:-$TARGET_HOME/vps-setup.log}"
exec > >(tee -a "$LOGFILE") 2>&1
log "Logging to $LOGFILE ($(date -u '+%Y-%m-%dT%H:%M:%SZ'))"

# Run each module in filename order.
for module in "$SCRIPT_DIR"/modules/[0-9]*.sh; do
  # shellcheck source=/dev/null
  . "$module"
done

# ---------------------------------------------------------------------------
log "Setup complete."
cat <<EOF

Open a new shell (or \`source ~/.bashrc\`) so PATH changes take effect.

Manual auth steps, as needed:
  - tailscale:  sudo tailscale up
  - gh:         gh auth login
  - claude:     claude     (sign in on first run)
  - codex:      codex      (sign in with ChatGPT)

Security applied: ufw firewall, fail2ban, automatic security updates, and
key-only SSH. If you created an admin user, VERIFY 'ssh ${ADMIN_USER:-<user>}@<host>'
and 'sudo -v' work before disabling root login (DISABLE_ROOT_LOGIN=1).
EOF
