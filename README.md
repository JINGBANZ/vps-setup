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
- **ufw** — a basic firewall so the box is sensible to expose.
- **git / curl / unzip** — the baseline plumbing everything else relies on.

## Quick start

```bash
git clone https://github.com/JINGBANZ/vps-setup.git && cd vps-setup
./setup.sh                          # tools + security (add sudo if not root)
source ~/.bashrc                    # pick up new PATH (nvm, bun, claude, codex)
```

To also create a non-root admin user in the same run:

```bash
ADMIN_USER=deploy ./setup.sh
```

## Project structure

The script is modular: a thin orchestrator sources shared helpers, then runs each
module in `modules/` in filename order. To change one concern, edit one file.

```
setup.sh              # orchestrator: sources lib, loops over modules/, logs output
lib/
  common.sh           # helpers (log/skip/ok/warn), SUDO, have(), env knobs
modules/
  10-apt-tools.sh     # git, curl, unzip, tmux, mosh, ufw
  20-gh.sh            # GitHub CLI (signed apt repo)
  30-tailscale.sh     # Tailscale
  40-node-bun.sh      # nvm + Node.js (LTS) + Bun
  50-agents.sh        # Claude Code + Codex CLI
  60-firewall.sh      # ufw (default-deny; SSH/mosh/tailscale allowed first)
  70-fail2ban.sh      # fail2ban sshd jail
  80-auto-updates.sh  # unattended-upgrades
  90-admin-user.sh    # non-root sudo user (only when ADMIN_USER is set)
  99-ssh-harden.sh    # key-only SSH (guarded against lockout)
```

Modules run in order, so dependencies are guaranteed (e.g. `unzip` before Bun;
the admin user is created *before* SSH hardening touches root login). Adding a
step is just dropping a numbered file into `modules/`.

## What the script does

When you run `setup.sh`, each module runs in order:

1. **Checks the platform.** Confirms `apt-get` exists (Debian/Ubuntu). If not, it
   exits early rather than doing anything unexpected on an unsupported distro.
2. **Decides on `sudo`.** If you're already root it runs commands directly;
   otherwise it prefixes privileged commands with `sudo`.
3. **Installs the apt tools** — `git`, `curl`, `unzip`, `tmux`, `mosh`, `ufw`.
   It first filters the list down to only what's missing, and runs
   `apt-get update` + `install` only if there's actually something to install.
4. **Installs `gh` (GitHub CLI)** from GitHub's official signed apt repository —
   adds the keyring to `/etc/apt/keyrings`, writes the repo to
   `/etc/apt/sources.list.d/github-cli.list`, then installs.
5. **Installs Tailscale** via the official `tailscale.com/install.sh` script.
6. **Installs `nvm`** (Node Version Manager) from the official pinned release,
   then sources it into the current shell so it's usable immediately.
7. **Installs Node.js (LTS)** through nvm (`nvm install --latest-npm 'lts/*'`) and sets it as the
   default version.
8. **Installs Bun** via the official `bun.com/install` script. (This is why
   `unzip` is installed first — Bun's installer requires it.)
9. **Installs Claude Code** using the official native installer.
10. **Installs Codex CLI** using OpenAI's official install script.
11. **Applies the security layer** (see below) — firewall, fail2ban, automatic
    security updates, and key-only SSH.
12. **Prints next steps** — a reminder to reload your shell and the manual
    authentication commands listed below.

Everything the script prints is also appended to a logfile (`~/vps-setup.log` by
default), so a failed run can be inspected afterward.

### Security hardening (always applied)

Security is **not optional** — these run on every invocation:

- **ufw firewall** — default-deny inbound. SSH, mosh, and the `tailscale0`
  interface are allowed *before* the firewall is enabled, so it can't lock you
  out.
- **fail2ban** — bans an IP for 24h after 3 failed SSH logins in an hour,
  blunting brute-force attacks.
- **unattended-upgrades** — security patches install automatically via the daily
  apt timer.
- **SSH hardening** — disables password authentication (key-only) and restricts
  root to key-only login. **Guarded:** if no SSH `authorized_keys` is found for
  root or your user, this step is **skipped** so you're never locked out — add
  your key with `ssh-copy-id` and re-run to enable it. The new `sshd` config is
  validated with `sshd -t` before reload and reverted if invalid.

### Non-root admin user (opt-in via `ADMIN_USER`)

Running as a non-root user with `sudo` is the recommended way to use the box —
your AI agents then run with limited permissions, and every elevation is logged
via `sudo`. Set `ADMIN_USER` and the `90-admin-user.sh` module creates one:

```bash
ADMIN_USER=deploy ./setup.sh
```

It creates the user, adds it to the `sudo` group, and installs an SSH key so you
can log in. The key is sourced in priority order:

1. `ADMIN_SSH_KEY="ssh-ed25519 AAAA…"` if you pass one, else
2. **root's existing `~/.ssh/authorized_keys`** — so if you already log into root
   with a key, the new user gets that same key automatically.

**End-to-end workflow:**

```bash
# 1. (laptop, once) create a key if you don't have one:
ssh-keygen -t ed25519
# 2. ensure root has your key (usually done at VPS creation, or):
ssh-copy-id root@SERVER_IP
# 3. (server) create the user:
ADMIN_USER=deploy ./setup.sh
# 4. (laptop, NEW terminal) VERIFY before trusting it:
ssh deploy@SERVER_IP        # logs in with your key?
sudo -v                     # sudo works?
# 5. only after step 4 succeeds, optionally lock root out entirely:
DISABLE_ROOT_LOGIN=1 ADMIN_USER=deploy ./setup.sh
```

**Safety:** by default root stays reachable *by key* (`prohibit-password`), so a
misconfigured admin user never locks you out. Fully disabling root login is
opt-in (`DISABLE_ROOT_LOGIN=1`) and only takes effect if an admin user with a key
exists. A key-only user has no password, so `sudo` needs either a password
(`sudo passwd deploy`) or passwordless sudo (`ADMIN_NOPASSWD_SUDO=1`).

### It's safe to re-run (idempotent)

Every step **checks whether the tool already exists and skips it if so**. Running
the script a second time on an already-set-up box installs nothing — it just
prints `already installed, skipping` for each tool. This means you can re-run it
any time to fill in whatever's missing without risk of duplicate installs.

### What it does *not* do

- It does **not** install developer tooling outside the list below.
- It does **not** perform interactive logins — those are left to you (see
  [Manual steps](#manual-steps-after-running)), because they require a browser /
  account and can't be safely scripted.
- It does **not** modify your dotfiles beyond what each official installer does
  on its own (the nvm/bun/claude/codex installers append their own PATH lines to
  `~/.bashrc`).
- It does **not** create a non-root admin user *unless you ask it to* by setting
  `ADMIN_USER` (see below). Without it, the box is set up but you keep logging in
  however you do now.

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
| ufw | Firewall — configured default-deny and enabled (see Security) | `apt` — official on Debian/Ubuntu |
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

## Configuration (env vars)

All knobs are defined in `lib/common.sh` and overridable from the environment:

| Variable | Default | Effect |
|----------|---------|--------|
| `ADMIN_USER` | *(unset)* | Create this non-root sudo user. Unset = skip. |
| `ADMIN_SSH_KEY` | *(unset)* | Public key for the admin user. Falls back to root's `authorized_keys`. |
| `ADMIN_NOPASSWD_SUDO` | `0` | `1` = grant the admin user passwordless sudo. |
| `DISABLE_ROOT_LOGIN` | `0` | `1` = `PermitRootLogin no` (only if an admin user with a key exists). |
| `SSH_PORT` | `22` | Port the firewall opens and fail2ban watches. |
| `NVM_VERSION` | `v0.40.5` | Pinned nvm release to install. |
| `LOGFILE` | `~/vps-setup.log` | Where run output is teed. |

Example:

```bash
ADMIN_USER=deploy ADMIN_NOPASSWD_SUDO=1 SSH_PORT=2222 ./setup.sh
```

To add or remove a base apt tool, edit the `APT_PKGS` array in
`modules/10-apt-tools.sh`. To add a whole new step, drop a numbered file into
`modules/`.
