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
- **ufw** — a firewall, installed here (configured in a later change).
- **git / curl / unzip** — the baseline plumbing everything else relies on.

## Quick start

```bash
git clone https://github.com/JINGBANZ/vps-setup.git && cd vps-setup
./setup.sh        # add sudo if you're not root
source ~/.bashrc  # pick up new PATH (nvm, bun, claude, codex)
```

## Project structure

The script is modular: a thin orchestrator sources shared helpers, then runs each
module in `modules/` in filename order. To change one concern, edit one file.

```
setup.sh              # orchestrator: sources lib, loops over modules/, logs output
lib/
  common.sh           # helpers (log/skip/ok/warn), SUDO, have(), settings
modules/
  10-apt-tools.sh     # git, curl, unzip, tmux, mosh, ufw
  20-gh.sh            # GitHub CLI (signed apt repo)
  30-tailscale.sh     # Tailscale
  40-node-bun.sh      # nvm + Node.js (LTS) + Bun
  50-agents.sh        # Claude Code + Codex CLI
```

Modules run in order, so dependencies are guaranteed (e.g. `unzip` before Bun).
Adding a step is just dropping a numbered file into `modules/`.

Everything the script prints is also appended to a logfile (`~/vps-setup.log` by
default, override with `LOGFILE=...`), so a failed run can be inspected afterward.

### It's safe to re-run (idempotent)

Every module **checks whether the tool already exists and skips it if so**.
Re-running on an already-set-up box installs nothing — it just prints
`skipping` for each tool. You can re-run any time to fill in whatever's missing
without risk of duplicate installs.

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
| ufw | Firewall (installed here; configured in a later change) | `apt` — official on Debian/Ubuntu |
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
