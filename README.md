# VPS Setup

`setup.sh` provisions a fresh **Debian/Ubuntu** VPS for an **AI-assisted
development workflow** in one command — getting a brand-new box ready to run AI
coding agents without manually running a dozen install commands. The toolset:

- **Claude Code** and **Codex CLI** — the AI coding agents themselves.
- **Node.js (via nvm)** and **Bun** — the JavaScript/TypeScript runtimes these
  agents and their tooling depend on.
- **gh** — lets the agents and you drive GitHub (PRs, issues, repos) from the CLI.
- **tmux** + **mosh** — keep long-running agent sessions alive across flaky/
  disconnected SSH connections, so a session survives a dropped link.
- **Tailscale** — private, secure network access to the VPS from anywhere.
- **ufw** + **fail2ban** + **unattended-upgrades** — baseline security: firewall,
  brute-force bans, and automatic security patches.
- **git / curl / unzip** — the baseline plumbing everything else relies on.

## Quick start

### Remote install (one command)

No clone needed — pipe the bootstrap into a shell. It downloads the repo to a
temp dir and runs `setup.sh`:

```bash
curl -fsSL https://raw.githubusercontent.com/JINGBANZ/vps-setup/main/bootstrap.sh | sudo bash
source ~/.bashrc  # pick up new PATH (nvm, bun, claude, codex)
```

Run this as a **non-root user with `sudo`** (not as root directly): user-level
tools — nvm, Bun, claude, codex — install for the invoking user (`$SUDO_USER`),
so `source ~/.bashrc` should be run as that same user. Piping straight to `bash`
as root instead would put those installs in root's home.

To pass env vars, set them **after** `sudo` (sudo scrubs the environment, so
`SSH_PORT=2222 … | sudo bash` would not reach the script):

```bash
curl -fsSL https://raw.githubusercontent.com/JINGBANZ/vps-setup/main/bootstrap.sh | sudo SSH_PORT=2222 bash
```

`bootstrap.sh` is a tiny loader (the same pattern the Claude/rustup installers
use): its whole body is wrapped in a function called on the last line, so a
dropped connection mid-download leaves a partial file that does nothing rather
than running a truncated script. Prefer `curl`, falls back to `wget`, then
`git`. It tracks `main`; override the source with `VPS_SETUP_REPO` /
`VPS_SETUP_REF`.

### Clone and run

```bash
git clone https://github.com/JINGBANZ/vps-setup.git && cd vps-setup
./setup.sh        # add sudo if you're not root
source ~/.bashrc  # pick up new PATH (nvm, bun, claude, codex)
```

## Project structure

The script is modular: a thin orchestrator sources shared helpers, then runs each
module in `modules/` in filename order. To change one concern, edit one file.

```
bootstrap.sh          # one-command remote installer: downloads the repo, runs setup.sh
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
```

Security (firewall/fail2ban/auto-updates) runs *before* the network-heavy
third-party installers, so a transient CDN failure can't leave the box
unhardened; the optional tool installers (Claude, Codex, Bun) soft-fail with a
warning rather than aborting the run.

Modules run in order, so dependencies are guaranteed (e.g. `unzip` before Bun).
Adding a step is just dropping a numbered file into `modules/`.

Everything the script prints is also appended to a logfile (`~/vps-setup.log` by
default, override with `LOGFILE=...`), so a failed run can be inspected afterward.

### Baseline security (automatic)

These are pure-win and carry no lockout risk, so they always run:

- **ufw firewall** — default-deny inbound. SSH, mosh, and the `tailscale0`
  interface are allowed *before* the firewall is enabled, so it can't lock you
  out. (Set `SSH_PORT` if SSH isn't on 22.)
- **fail2ban** — bans an IP for 24h after 3 failed SSH logins in an hour,
  blunting brute-force attacks. (Uses the `systemd` journal backend, so it pulls
  in `python3-systemd` — without which the jail silently fails to start.)
- **SSH hardening** — disables password and root-password logins (key auth keeps
  working). **Guarded:** it only flips this on if an authorized SSH key already
  exists for the account you log in as; on a password-only box it skips and warns
  rather than risk locking you out.
- **unattended-upgrades** — security patches install automatically via the daily
  apt timer.

### It's safe to re-run (idempotent)

Every module **checks whether the tool already exists and skips it if so**. The
security config files are managed with `write_config`, which **only rewrites a
file when its content actually differs** — so a no-op re-run touches no files and
restarts no services (fail2ban is only restarted when its jail changed).
Re-running on an already-set-up box changes nothing; you can re-run any time to
fill in whatever's missing without risk of duplicate installs.

The firewall is configured **only on first setup**: if `ufw` is already active,
the module skips entirely, so any rules or default-policy changes you made by
hand are preserved. The script-managed config *files* (fail2ban jail, SSH
hardening drop-in, unattended-upgrades) are the script's to own — edit a separate
drop-in instead of those if you want custom settings to survive a re-run.

## Tools installed

Every tool here is tailored to the AI-assisted development workflow — its role in
that workflow is listed alongside the official install method it uses.

| Tool | Role in the AI workflow | Install method (official) |
|------|-------------------------|---------------------------|
| Claude Code | AI coding agent | `curl -fsSL https://claude.ai/install.sh \| bash` (native installer) |
| Codex CLI | AI coding agent | `curl -fsSL https://chatgpt.com/codex/install.sh \| sh` |
| nvm | Manages the Node runtime the agents/tooling need | `nvm-sh` versioned `install.sh` (pinned to `v0.40.5`) |
| Node.js (LTS) | JS/TS runtime the agents and their tooling run on | `nvm install --latest-npm 'lts/*'` |
| Bun | Fast JS/TS runtime & package manager for agent tooling | `curl -fsSL https://bun.com/install \| bash` |
| gh (GitHub CLI) | Lets agents drive GitHub (PRs, issues, repos) from CLI | `cli.github.com` signed apt repo (official) |
| tmux | Keeps long-running agent sessions alive after disconnects | `apt` — official on Debian/Ubuntu |
| mosh | Resilient SSH for agent sessions over flaky links | `apt` — official on Debian/Ubuntu |
| Tailscale | Private, secure remote access to the agent box | `curl -fsSL https://tailscale.com/install.sh \| sh` |
| ufw | Firewall — configured default-deny and enabled (see Baseline security) | `apt` — official on Debian/Ubuntu |
| git | Version control the agents operate on | `apt` — official on Debian/Ubuntu |
| curl | Fetches the other installers; agent HTTP plumbing | `apt` — official on Debian/Ubuntu |
| unzip | Required by Bun's installer; general unpacking | `apt` — official on Debian/Ubuntu |

Each command was taken from the tool's **official documentation** so the setup
follows upstream best practice.

### Install order notes

- `unzip` is installed (via apt) **before Bun**, because Bun's installer requires it.
- `nvm` is installed **before Node.js**, then sourced so `nvm install` works
  in the same run.

## Manual steps after running

These need interactive auth and aren't automated:

- `sudo tailscale up` — authenticate the node to your tailnet
- `gh auth login` — log in to GitHub
- `claude` — sign in to Claude Code on first run
- `codex` — sign in with ChatGPT

## Customizing

- Pin a different nvm release with `NVM_VERSION=v0.40.x ./setup.sh`.
- To add or remove a base apt tool, edit the `APT_PKGS` array in
  `modules/10-apt-tools.sh`. To add a whole new step, drop a numbered file into
  `modules/`.
