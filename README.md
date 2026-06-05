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
./setup.sh        # add sudo if you're not root
source ~/.bashrc  # pick up new PATH entries (nvm, bun, claude, codex)
```

## What the script does

When you run `setup.sh`, it works through the following steps in order:

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
7. **Installs Node.js (LTS)** through nvm (`nvm install --lts`) and sets it as the
   default version.
8. **Installs Bun** via the official `bun.com/install` script. (This is why
   `unzip` is installed first — Bun's installer requires it.)
9. **Installs Claude Code** using the official native installer.
10. **Installs Codex CLI** using OpenAI's official install script.
11. **Prints next steps** — a reminder to reload your shell and the manual
    authentication commands listed below.

### It's safe to re-run (idempotent)

Every step **checks whether the tool already exists and skips it if so**. Running
the script a second time on an already-set-up box installs nothing — it just
prints `already installed, skipping` for each tool. This means you can re-run it
any time to fill in whatever's missing without risk of duplicate installs.

### What it does *not* do

- It does **not** install anything outside the list below.
- It does **not** perform interactive logins — those are left to you (see
  [Manual steps](#manual-steps-after-running)), because they require a browser /
  account and can't be safely scripted.
- It does **not** modify your dotfiles beyond what each official installer does
  on its own (the nvm/bun/claude/codex installers append their own PATH lines to
  `~/.bashrc`).

## Tools installed

Every tool here is tailored to the AI-assisted development workflow — its role in
that workflow is listed alongside the official install method it uses.

| Tool | Role in the AI workflow | Install method (official) |
|------|-------------------------|---------------------------|
| Claude Code | AI coding agent | `curl -fsSL https://claude.ai/install.sh \| bash` (native installer) |
| Codex CLI | AI coding agent | `curl -fsSL https://chatgpt.com/codex/install.sh \| sh` |
| nvm | Manages the Node runtime the agents/tooling need | `nvm-sh` versioned `install.sh` (pinned to `v0.40.5`) |
| Node.js (LTS) | JS/TS runtime the agents and their tooling run on | `nvm install --lts` |
| Bun | Fast JS/TS runtime & package manager for agent tooling | `curl -fsSL https://bun.com/install \| bash` |
| gh (GitHub CLI) | Lets agents drive GitHub (PRs, issues, repos) from CLI | `cli.github.com` signed apt repo (official) |
| tmux | Keeps long-running agent sessions alive after disconnects | `apt` — official on Debian/Ubuntu |
| mosh | Resilient SSH for agent sessions over flaky links | `apt` — official on Debian/Ubuntu |
| Tailscale | Private, secure remote access to the agent box | `curl -fsSL https://tailscale.com/install.sh \| sh` |
| ufw | Basic firewall so the box is safe to expose | `apt` — official on Debian/Ubuntu |
| git | Version control the agents operate on | `apt` — official on Debian/Ubuntu |
| curl | Fetches the other installers; agent HTTP plumbing | `apt` — official on Debian/Ubuntu |
| unzip | Required by Bun's installer; general unpacking | `apt` — official on Debian/Ubuntu |

Each command was taken from the tool's **official documentation** so the setup
follows upstream best practice.

### Install order notes

- `unzip` is installed (via apt) **before Bun**, because Bun's installer requires it.
- `nvm` is installed **before Node.js**, then sourced so `nvm install --lts` works
  in the same run.

## Manual steps after running

These need interactive auth and aren't automated:

- `sudo tailscale up` — authenticate the node to your tailnet
- `gh auth login` — log in to GitHub
- `claude` — sign in to Claude Code on first run
- `codex` — sign in with ChatGPT

## Customizing

- Pin a different nvm release by editing `NVM_VERSION` at the top of `setup.sh`.
- To add or remove an apt tool, edit the `APT_PKGS` array.
