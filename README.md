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
./setup.sh                          # add sudo if you're not root
source ~/.bashrc                    # pick up new PATH (nvm, bun, claude, codex)
```

The script **asks before each optional step** — there are no flags to remember.
It installs the tools and baseline firewall automatically, then prompts:

```
?? Create a non-root admin user (passwordless sudo)? [y/N]
?? Harden SSH to key-only login (disable password auth)? [Y/n]
```

Answer `y`/`n` as you like. On a non-interactive run (cron/CI, no terminal) the
prompts fall back to safe defaults (skip the admin user; harden only if a key
already exists).

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
  90-admin-user.sh    # non-root sudo user (prompts; opt-in)
  99-ssh-harden.sh    # key-only SSH (prompts; never locks root out)
```

Modules run in order, so dependencies are guaranteed (e.g. `unzip` before Bun;
the admin user is created *before* SSH hardening changes login rules). Adding a
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
11. **Applies baseline security** (see below) — firewall, fail2ban, and automatic
    security updates, automatically.
12. **Prompts for the optional steps** — creating a non-root admin user, and
    hardening SSH to key-only login.
13. **Prints next steps** — a reminder to reload your shell and the manual
    authentication commands listed below.

Everything the script prints is also appended to a logfile (`~/vps-setup.log` by
default), so a failed run can be inspected afterward.

### Baseline security (automatic)

These are pure-win and carry no lockout risk, so they always run:

- **ufw firewall** — default-deny inbound. SSH, mosh, and the `tailscale0`
  interface are allowed *before* the firewall is enabled, so it can't lock you
  out.
- **fail2ban** — bans an IP for 24h after 3 failed SSH logins in an hour,
  blunting brute-force attacks.
- **unattended-upgrades** — security patches install automatically via the daily
  apt timer.

### SSH hardening (prompted) — and root is never locked out

The script asks `Harden SSH to key-only login? [Y/n]`. If you accept, it disables
password authentication so only SSH keys work. **Root is never locked out:**

- It **never** disables root login. Root always stays reachable **by key**
  (`PermitRootLogin prohibit-password`).
- Before turning passwords off, it makes sure **root has a key** (installing the
  resolved key if root has none). If no key can be obtained at all, it **leaves
  password authentication on** rather than risk a lockout.
- The new `sshd` config is validated with `sshd -t` and reverted if invalid.

### Non-root admin user (prompted)

Running as a non-root user with `sudo` is the recommended way to use the box —
your AI agents then run with limited permissions, and every elevation is logged
via `sudo`. The script asks `Create a non-root admin user (passwordless sudo)?`
If you say yes, it:

1. asks for a **username** (default `dev`),
2. creates the user, adds it to the `sudo` group, with **passwordless sudo**,
3. installs an SSH key, resolved in priority order:
   - **root's existing `~/.ssh/authorized_keys`** (so if you already log into root
     with a key, the new user inherits it automatically), else
   - it **prompts you to paste a public key**, which it stores for the user.

**End-to-end workflow:**

```bash
# 1. (laptop, once) create a key if you don't have one:
ssh-keygen -t ed25519
# 2. ensure root has your key (usually done at VPS creation, or):
ssh-copy-id root@SERVER_IP
# 3. (server) run the script and answer the prompts:
./setup.sh
#    ?? Create a non-root admin user (passwordless sudo)? y
#    ?? Username for the admin user: [dev] <enter>
# 4. (laptop, NEW terminal) VERIFY before logging out:
ssh dev@SERVER_IP        # logs in with your key?
sudo -v                  # passwordless sudo works?
```

The new `dev` user has passwordless sudo and key-only login. Root stays reachable
by key the whole time, so nothing you do here can lock you out.

### It's safe to re-run (idempotent)

Every module **checks whether the tool already exists and skips it if so**. The
security config files are managed with `write_config`, which **only rewrites a
file when its content actually differs** — so a no-op re-run touches no files and
restarts no services (fail2ban and sshd are only reloaded when their config
changed). Re-running on an already-set-up box changes nothing; you can re-run any
time to fill in whatever's missing without risk of duplicate installs.

### What it does *not* do

- It does **not** install developer tooling outside the list below.
- It does **not** perform interactive logins — those are left to you (see
  [Manual steps](#manual-steps-after-running)), because they require a browser /
  account and can't be safely scripted.
- It does **not** modify your dotfiles beyond what each official installer does
  on its own (the nvm/bun/claude/codex installers append their own PATH lines to
  `~/.bashrc`).
- It does **not** create a non-root admin user *unless you answer yes* at the
  prompt. Decline it and the box is set up but you keep logging in however you do
  now.
- It does **not** ever disable root login — root always stays reachable by key.

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

## Configuration

Opting in/out of features is **interactive** (the prompts above) — there are no
feature flags. The only env vars are a few plain settings with sane defaults,
defined in `lib/common.sh`:

| Variable | Default | Effect |
|----------|---------|--------|
| `SSH_PORT` | `22` | Port the firewall opens and fail2ban watches. |
| `NVM_VERSION` | `v0.40.5` | Pinned nvm release to install. |
| `LOGFILE` | `~/vps-setup.log` | Where run output is teed. |

Example (only needed if SSH isn't on port 22):

```bash
SSH_PORT=2222 ./setup.sh
```

To add or remove a base apt tool, edit the `APT_PKGS` array in
`modules/10-apt-tools.sh`. To add a whole new step, drop a numbered file into
`modules/`.
