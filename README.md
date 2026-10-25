# VPS Setup

Set up a **Debian/Ubuntu VPS or Mac mini** for terminal development with Codex,
Claude Code, Mosh and tmux. Both platforms share the same interactive onboarding.

## Run

Run this **on the machine you want to set up**, as your normal user, without
prefixing the command with sudo:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/JINGBANZ/vps-setup/main/bootstrap.sh)"
```

No clone or pull is needed. Setup downloads into a temporary directory and
cleans up on exit. Linux requests sudo when selected system work needs it;
macOS's Homebrew installer may request administrator authorization. Direct root
use remains supported on Linux for installations intended for root. An outer
`sudo` invocation from a normal account is rejected to avoid installing that
user's tools and shell configuration as root.

Use **↑/↓** to move, **Space** to toggle, **Ctrl-A** for all/none, and **Enter**
to continue. Review the plan and choose **Install** or **Cancel** (the default).
**Esc / Ctrl-C** cancels. Installed tools and broken installations appear in a
read-only summary, without checkboxes; broken tools need manual repair.

The script bootstraps [Gum v0.17.0](https://github.com/charmbracelet/gum/releases/tag/v0.17.0)
on the server running setup, not on the laptop displaying an SSH session. It
reuses an installed matching version, or downloads the OS/architecture-specific
binary temporarily and verifies a pinned SHA-256 before extracting or running
it. No Homebrew or apt installation is needed for the UI. The temporary copy is
removed on exit; a subsequent run downloads it again unless a matching Gum is
already installed. If preparation fails, interactive setup stops before
provisioning. **There is no numbered menu.**

## Choose what runs

| Choice | macOS | Debian/Ubuntu | Default if missing |
| --- | --- | --- | --- |
| Tailscale, Mosh, tmux, Git, GitHub CLI | Homebrew (existing Apple Git also kept) | apt / official upstream installer or repository | Selected |
| Codex, Claude Code | Official native installers | Same native installers | Selected |
| Node.js / nvm, Bun | Official installers | Same installers | Off |
| Session shortcut `t`, shell integration | Shared managed bash/zsh configuration | Same configuration | Selected |
| Security baseline | Not offered | Guarded SSH hardening, ufw, fail2ban, automatic security updates | Selected |
| Disk guard | Not offered | Journal cap and disk timer; Docker cache cleanup at threshold | Selected |
| Actions runner, PostgreSQL | Not offered | Dedicated runner service / local database service | Off |

Homebrew is a conditional dependency, installed only for a selected missing
formula. A selected shortcut adds missing tmux; selected tools add shell
integration. On Linux, missing `curl` is added only for selected network
installers (including the runner); Bun also adds missing `unzip`. These apt
dependencies appear in the review plan and install before dependent tools.
Existing Tailscale
installations and credentials are preserved. No client connectivity tests run.

On Linux, security and disk guard are **configuration reconciliation** choices:
they remain selectable so changed settings can be applied; their modules compare
managed files before writing. They run before third-party tool installers when
selected. Active ufw rules are preserved. SSH password authentication is disabled
only when an authorized key is found for the invoking account. Set `SSH_PORT`
before setup if it is not 22. Review the firewall plan for your server's needs.

Disk guard caps the journal at 200 MB, checks every 10 minutes, warns at 80%,
and prunes Docker build cache and dangling images at 90%. Override thresholds
with `DISK_GUARD_WARN_PCT` / `DISK_GUARD_CLEAN_PCT`.

Runner installation requires `GH_RUNNER_REPO=owner/repo` plus an authenticated
GitHub CLI or `GH_RUNNER_TOKEN`. Use it only for trusted repositories: workflows
execute code on the server. `DEV_POSTGRES=1` preselects PostgreSQL; it uses local
Unix sockets and peer authentication with a superuser role for the invoking
account. Both choices remain subject to the same review and installed-item locks.

## Preview or automate

Pass options through the same bootstrap command on either OS:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/JINGBANZ/vps-setup/main/bootstrap.sh)" -- --check
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/JINGBANZ/vps-setup/main/bootstrap.sh)" -- --select mosh,tmux,shortcut --dry-run
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/JINGBANZ/vps-setup/main/bootstrap.sh)" -- --select mosh,tmux,shortcut --yes
```

`--check` inventories local state; `--dry-run` prints a plan. Neither writes
configuration or installs software. `--yes` requires an explicit `--select`
list (`none` is valid). All three modes skip Gum. IDs are
`tailscale,mosh,tmux,git,gh,codex,claude,node,bun,shortcut,shell`, plus Linux-only
`security,disk-guard,runner,postgres`.

Reruns redetect tools before applying saved choices and recheck before installing.
Working tools cannot be selected for reinstall; deselection never uninstalls.
Managed shell files are compared, original files backed up once, and custom lines
preserved. Symlinked profiles needing changes require manual integration.
Failures exit nonzero; fix the reported issue and rerun. Linux installation output
is saved to `~/vps-setup.log` (override with `LOGFILE`). Configuration reconciliation
may enable stopped services; this is not an assurance that services never change.

## After setup

Open a new shell. Sign in to selected tools when needed (`sudo tailscale up`,
`gh auth login`, `claude`, `codex`). On macOS, Remote Login, Screen Sharing,
power settings and Tailscale service startup stay manual: see the
[Mac mini guide](macos/README.md) and [visual walkthrough](macos/design.html).

`t task-name` creates or resumes a tmux session in `~/workspace` (override with
`WORKSPACE_DIR`). **Ctrl-b, then d** detaches; **Ctrl-b, then s** switches sessions.
Live sessions survive terminal disconnects, but not a server reboot.

## Modular design

Both operating systems run `setup.sh` → `lib/setup.sh`:

| File | Responsibility |
| --- | --- |
| `bootstrap.sh` | Download repository temporarily and forward options |
| `lib/setup.sh` | Shared inventory → selection → plan → apply → summary |
| `lib/onboarding.sh` | Registry, eligibility, dependencies and managed shell configuration |
| `lib/onboarding-ui.sh` | Shared Gum checklists and locked-item presentation |
| `lib/terminal-ui.sh` | Pinned Gum bootstrap, verification and cleanup |
| `macos/platform.sh` | Apple tool detection and conditional Homebrew installation |
| `linux/platform.sh` | apt detection, selected package installation and Linux module dispatch |
| `modules/*.sh` | Existing focused installers and system configuration modules |

Add shared choices to the shared registry/engine; keep platform-specific work in
an adapter. Merely adding a numbered module file does not execute it automatically.
Native agent/runtime installers and the tmux helper are reused by both platforms.

CI runs isolated installer tests and real Gum keyboard tests on Linux and macOS
(Apple Bash 3.2), shell lint, and fresh Ubuntu apt regression tests. The behavior
tests fake provisioning commands; they do not provision a physical Mac or VPS.
