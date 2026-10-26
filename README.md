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
to continue. Review the plan and choose **Apply** or **Cancel** (the default).
**Esc / Ctrl-C** cancels. Installed tools and broken installations appear in a
read-only summary, without checkboxes; broken tools need manual repair. Selection
summaries stay on screen, followed by a bulleted action plan. Results list only
attempted work and relevant next steps. An empty plan exits without confirmation.

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

`--check` shows installed versions, paths and repair details; `--dry-run` prints a plan. Neither writes
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

Shell integration covers interactive sessions and direct SSH commands in Bash
and Zsh, including Homebrew, native tools and nvm-managed Node. See the
[shell startup contract](docs/shell-startup.md) for background jobs and test coverage.

Interactive setup offers optional [GitHub authentication](#github-authentication)
after successful installation or configuration. Open a new shell to load shell
changes, and sign in to other tools when needed (`sudo tailscale up`, `claude`,
`codex`). On macOS, Remote Login, Screen Sharing,
power settings and Tailscale service startup stay manual: see the
[Mac mini guide](macos/README.md) and [visual walkthrough](macos/design.html).

`t task-name` creates or resumes a tmux session in `~/workspace` (override with
`WORKSPACE_DIR`). **Ctrl-b, then d** detaches; **Ctrl-b, then s** switches sessions.
Live sessions survive terminal disconnects, but not a server reboot.

### GitHub authentication

When GitHub CLI is available after successful interactive setup, a separate
**Sign in / Skip** prompt offers to configure GitHub authentication. **Skip is
the default.** Accepting checks the active `github.com` login, keeps working
credentials, configures Git to use GitHub CLI for HTTPS credentials, and displays
the final authentication status. Existing Git protocol preferences are retained;
new logins use HTTPS and GitHub's browser/device-code flow. Over SSH, open the
displayed GitHub URL on your own computer and enter the displayed code.

On macOS, if authentication is unavailable, setup first runs
`security unlock-keychain "$HOME/Library/Keychains/login.keychain-db"` in the
same terminal. Enter the Mac's login Keychain password at the native prompt.
Setup never captures or stores that password. If unlocking restores an existing
login, no new login runs; if unlocking fails, setup stops the authentication step.
Password prompts and device codes bypass the Linux installation log.

`--check`, `--dry-run`, `--yes`, cancelled plans, failed installations, and runs
with no selected changes never enter this step. Skipping or failing authentication
leaves completed installation work intact and does not change its exit status.
`GH_TOKEN` / `GITHUB_TOKEN` authentication is checked and kept, without starting
a browser login or unlocking Keychain. A valid existing file-stored token is also
kept; this step does not migrate credentials. Git commit name/email remain yours
to configure separately.

If you skipped the step, sign in from your workstation terminal or SSH session:

```bash
# macOS must unlock successfully before login. Linux skips the unlock command.
if [ "$(uname -s)" != Darwin ] ||
  security unlock-keychain "$HOME/Library/Keychains/login.keychain-db"; then
  gh auth login --hostname github.com --git-protocol https --web &&
    gh auth setup-git --hostname github.com &&
    gh auth status --active --hostname github.com
fi
```

For an existing login, start with `gh auth status --active --hostname github.com`.
If the Mac Keychain has locked, unlock it in that same session and check again;
you may not need to log in again. `(keyring)` in the status confirms system
credential storage. A configuration-file path means plaintext storage: GitHub CLI
can fall back to a file if it cannot use the system credential store. A successful
GitHub login alone does not prove Keychain storage. See the official
[GitHub CLI login](https://cli.github.com/manual/gh_auth_login),
[Git credential helper](https://cli.github.com/manual/gh_auth_setup-git), and
[Apple SSH/Keychain guidance](https://developer.apple.com/forums/thread/712005).

## Modular design

Both operating systems run `setup.sh` → `lib/setup.sh`:

| File | Responsibility |
| --- | --- |
| `bootstrap.sh` | Download repository temporarily and forward options |
| `lib/setup.sh` | Shared inventory → selection → plan → apply → summary |
| `lib/onboarding.sh` | Registry, eligibility, dependencies and managed shell configuration |
| `lib/onboarding-ui.sh` | Shared Gum checklists and locked-item presentation |
| `lib/github-auth.sh` | Optional interactive GitHub authentication after installation |
| `lib/terminal-ui.sh` | Pinned Gum bootstrap, verification and cleanup |
| `macos/platform.sh` | Apple tool detection and conditional Homebrew installation |
| `linux/platform.sh` | apt detection, selected package installation and Linux module dispatch |
| `modules/*.sh` | Existing focused installers and system configuration modules |

Add shared choices to the shared registry/engine; keep platform-specific work in
an adapter. Merely adding a numbered module file does not execute it automatically.
Native agent/runtime installers and the tmux helper are reused by both platforms.

CI runs isolated installer tests and real Gum keyboard tests on Linux and macOS
(Apple Bash 3.2), real shell/nvm startup tests, isolated SSH/Mosh/tmux tests,
shell lint, and fresh Ubuntu apt regression tests. The behavior
tests fake provisioning commands; they do not provision a physical Mac or VPS.
