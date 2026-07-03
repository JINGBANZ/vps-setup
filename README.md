# VPS Setup

`setup.sh` provisions a fresh **Debian/Ubuntu** VPS for an **AI-assisted
development workflow** in one command — installing AI coding agents, their
runtimes, and a baseline security setup so a brand-new box is ready to use.

## Quick start

Run this on the VPS as a **non-root user with `sudo`**:

```bash
curl -fsSL https://raw.githubusercontent.com/JINGBANZ/vps-setup/main/bootstrap.sh | sudo bash
source ~/.bashrc   # load the new PATH (nvm, bun, claude, codex)
```

That's it. The bootstrap downloads the repo and runs `setup.sh`.

Prefer to clone first? Same result:

```bash
git clone https://github.com/JINGBANZ/vps-setup.git && cd vps-setup
sudo ./setup.sh
source ~/.bashrc
```

## Tools installed

Each command is taken from the tool's official documentation.

| Tool | Role in the AI workflow | Install method |
|------|-------------------------|----------------|
| Claude Code | AI coding agent | `curl -fsSL https://claude.ai/install.sh \| bash` |
| Codex CLI | AI coding agent | `curl -fsSL https://chatgpt.com/codex/install.sh \| sh` |
| nvm | Manages the Node runtime | `nvm-sh` versioned `install.sh` (pinned `v0.40.5`) |
| Node.js (LTS) | JS/TS runtime the agents run on | `nvm install --latest-npm 'lts/*'` |
| Bun | Fast JS/TS runtime & package manager | `curl -fsSL https://bun.com/install \| bash` |
| gh (GitHub CLI) | Drive GitHub (PRs, issues, repos) from CLI | `cli.github.com` signed apt repo |
| tmux | Keeps agent sessions alive after disconnects | `apt` |
| mosh | Resilient SSH over flaky links | `apt` |
| Tailscale | Private, secure remote access | `curl -fsSL https://tailscale.com/install.sh \| sh` |
| ufw | Firewall (see Baseline security) | `apt` |
| git / curl / unzip | Version control + installer plumbing | `apt` |

## Baseline security

Firewall, fail2ban, and auto-updates run *before* the network-heavy third-party
installers, so a transient CDN failure can't leave the box unhardened. These are
pure-win with no lockout risk, so they always run:

- **ufw firewall** — default-deny inbound. SSH, mosh, and `tailscale0` are
  allowed *before* the firewall is enabled, so it can't lock you out. (Set
  `SSH_PORT` if SSH isn't on 22.) Configured only on first setup — if `ufw` is
  already active the module skips, preserving any hand-made rules.
- **fail2ban** — bans an IP for 24h after 3 failed SSH logins in an hour.
- **SSH hardening** — disables password and root-password logins. **Guarded:**
  only flips on if an authorized SSH key already exists for your account; on a
  password-only box it skips and warns rather than risk locking you out.
- **unattended-upgrades** — security patches install automatically.

## Project structure

A thin orchestrator sources shared helpers, then runs each module in `modules/`
in filename order. To change one concern, edit one file; to add a step, drop a
numbered file into `modules/`.

```
bootstrap.sh          # one-command remote installer
setup.sh              # orchestrator: sources lib, loops over modules/, logs output
lib/
  common.sh           # helpers (log/skip/ok/warn), SUDO, have(), settings
modules/
  10-apt-tools.sh     # git, curl, unzip, tmux, mosh, ufw
  15-ssh-hardening.sh # key-only SSH (guarded: skips if no key is present)
  20-firewall.sh      # ufw (default-deny; SSH/mosh/tailscale allowed first)
  25-fail2ban.sh      # fail2ban sshd jail
  30-auto-updates.sh  # unattended-upgrades
  40-gh.sh            # GitHub CLI (signed apt repo)
  50-tailscale.sh     # Tailscale
  60-node-bun.sh      # nvm + Node.js (LTS) + Bun
  70-agents.sh        # Claude Code + Codex CLI
  80-tmux.sh          # `t` shortcut for per-task tmux sessions (in $WORKSPACE_DIR)
```

Optional tool installers (Claude, Codex, Bun) soft-fail with a warning rather
than aborting the run. All output is appended to a logfile (`~/vps-setup.log` by
default, override with `LOGFILE=...`).

**Idempotent:** every module skips a tool that already exists, and config files
are only rewritten when their content differs — so a re-run on an already-set-up
box changes nothing and restarts no services. Re-run any time to fill in
whatever's missing.

## Manual steps after running

These need interactive auth and aren't automated:

- `sudo tailscale up` — authenticate the node to your tailnet
- `gh auth login` — log in to GitHub
- `claude` — sign in to Claude Code on first run
- `codex` — sign in with ChatGPT

## Session workflow

`80-tmux.sh` sets up one named **tmux** session per task, each rooted at your
repo directory (`$WORKSPACE_DIR`, default `/workspace`) — no extra tools, just
tmux:

- **New / resume a task:** `t <task>` — a shell shortcut that attaches the
  session if it exists or creates it in `$WORKSPACE_DIR` (bare `t` uses `main`).
- **Switch tasks:** `prefix + s` (tmux's built-in session picker).

Point it at a different directory by setting `WORKSPACE_DIR` when you run setup
(e.g. `WORKSPACE_DIR=/srv/code sudo ./setup.sh`). Re-running with a new value
refreshes the `t` shortcut in place. `detach-on-destroy` is left at the tmux
default, so finishing a task detaches you — handy when each task lives in its own
cmux tab that you just close when done. Pair it with a cmux custom command that
lands you on the box in one keypress:

```
cmux ssh clouddesk -- tmux new-session -A -s main -c /workspace
```

## Customizing

- **Run as non-root with `sudo`**, not as root directly — user-level tools (nvm,
  Bun, claude, codex) install for `$SUDO_USER`, and `source ~/.bashrc` loads
  their PATH for that user.
- **Pass env vars after `sudo`** (sudo scrubs the environment), e.g. set a
  non-standard SSH port:
  ```bash
  curl -fsSL .../bootstrap.sh | sudo SSH_PORT=2222 bash
  ```
- Pin a different nvm release with `NVM_VERSION=v0.40.x`.
- Set where the `t` shortcut opens sessions with `WORKSPACE_DIR=/path` (default
  `/workspace`).
- Install from a fork/branch with `VPS_SETUP_REPO` / `VPS_SETUP_REF` (defaults
  to this repo's `main`).
- Add or remove base apt tools via the `APT_PKGS` array in
  `modules/10-apt-tools.sh`.
