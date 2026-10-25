# Mac mini server installation

Run setup on the Mac mini as your normal administrator user, **without sudo**.
It installs missing development tools and optionally configures your shell.
It does not configure SSH, Screen Sharing, power, credentials or network access.
Your existing Tailscale installation is kept, including its service state.

## Start

Run this **on your Mac mini**, in Terminal or an interactive SSH session,
**without sudo**:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/JINGBANZ/vps-setup/main/bootstrap.sh)"
```

The bootstrap downloads the latest `main` into a temporary directory, runs
interactive onboarding, then removes that directory on exit. No permanent
repository checkout or manual pull is needed. Using `bash -c` keeps terminal
input available for onboarding and Homebrew prompts.

Installed tools, including existing Tailscale, stay locked and unchanged. Toggle
eligible numbers, press **Enter** to review, then type **`apply`** to proceed.
Rerun the same command later to install missing tools. After shell configuration,
open a new terminal or SSH session to load it.

Homebrew is added only when a selected missing formula needs it. Its initial
installer may request your administrator password. If Command Line Tools are
missing, run `xcode-select --install`, finish Apple's installer, then rerun setup.
Skip that step if the tools are already installed. Use a macOS version supported
by [Homebrew](https://docs.brew.sh/Installation).

For a local inventory or a plan without installing anything, pass flags after
`--` (the placeholder for Bash's `$0`, so later arguments reach the bootstrap):

```bash
# Local inventory only; still downloads setup into a temporary directory.
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/JINGBANZ/vps-setup/main/bootstrap.sh)" -- --check

# Preview selected work.
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/JINGBANZ/vps-setup/main/bootstrap.sh)" -- --select mosh,tmux,codex --dry-run
```

### Optional local checkout

If you prefer keeping the scripts locally:

```bash
git clone https://github.com/JINGBANZ/vps-setup.git
cd vps-setup
bash setup.sh

# These commands run from the checkout:
bash setup.sh --check
bash setup.sh --select mosh,tmux,codex --dry-run
bash setup.sh --select mosh,tmux,shortcut,codex,claude --yes
bash setup.sh --select none --yes
```

`--yes` requires an explicit list and skips this script's confirmation. An upstream
installer, notably Homebrew on first installation, can still request input or
administrator authorization. Linux rejects these Mac-only flags.

## Menu: nine tools and two configuration choices

Every run redetects the local installation before applying saved choices.

| Local state | Menu behavior | What setup does |
| --- | --- | --- |
| Installed command passes its version check | **LOCKED**, no checkbox | Keep it, even outside Homebrew |
| Tailscale app, daemon or formula present | **LOCKED**, no checkbox | Keep it without checking service/authentication state |
| Existing command fails, formula lacks a command, or a known install path is unusable | **LOCKED**, manual repair | No reinstall or overwrite |
| Missing tool | Selectable | Install only if selected |
| Configuration matches | **LOCKED**, no checkbox | No rewrite |
| Configuration needs updating | Selectable | Compare and write changed content |
| Configuration needs changing through a symlink | **LOCKED**, manual repair | Preserve the symlink and target |

Toggle eligible numbers, use `all`, `none`, or `defaults`, then press Enter to
review the plan. Type `apply` to proceed; anything else cancels. Locked entries
cannot be selected or deselected, including through bulk commands or `--select`.
Selecting an already installed tool alone does nothing.

| ID | Purpose / installation | Default if eligible |
| --- | --- | --- |
| `tailscale` | Homebrew formula for a new installation only | Selected |
| `mosh` | Homebrew formula; installs the terminal server executable | Selected |
| `tmux` | Homebrew formula; keeps sessions through disconnects | Selected |
| `git` | Existing Apple/other Git is reused; otherwise Homebrew | Selected |
| `gh` | GitHub CLI via Homebrew | Selected |
| `codex` | Official native installer; independent of Node | Selected |
| `claude` | Official native installer; independent of Node | Selected |
| `node` | Existing Node reused; otherwise nvm and Node LTS | Off |
| `bun` | Official native installer | Off |
| `shortcut` | Configure `t NAME` and create `WORKSPACE_DIR` | Selected |
| `shell` | Configure PATH and managed zsh/bash initialization | Selected |

The last two entries appear in a separate **Configuration** section. A selected
shortcut requires tmux: a missing tmux is added, while a broken tmux blocks the
shortcut. Selected tools/shortcut add shell integration when it is not blocked,
so new commands can be found in future shells. The plan shows this dependency;
configuration can be scheduled even if it currently matches, because installing
Homebrew or nvm can change the required initialization. If its final content
matches, the file is not rewritten.

Homebrew is **not a separate optional module**. It is reused, or installed once
when selected missing `tailscale`, `mosh`, `tmux`, `git` or `gh` requires it.
A broken Homebrew blocks that plan with a manual repair message. Native agents,
Node/Bun and configuration alone do not install Homebrew.

### What runs under the hood

`setup.sh` dispatches to `macos/setup.sh`, which uses `macos/lib.sh` and shared
`lib/common.sh`. It does **not** run the Linux module directory in order.

| Selected work | Implementation |
| --- | --- |
| Missing formula tools | `macos/setup.sh`: one `brew install --formula TOOL` per selected tool |
| Node or Bun | `modules/60-node-bun.sh`, separately per selected runtime with independent flags |
| Codex or Claude | `modules/70-agents.sh`, separately per selected agent with independent flags |
| Session shortcut | `modules/80-tmux.sh` generates a temporary desired file; changed content is applied |
| Shell integration | `macos/lib.sh`: compare and update managed initialization |

Thus the amount of installation work depends on selection and detected state,
not a fixed count of modules. Read-only inventory also generates a temporary
shortcut for comparison, but does not persist it or install anything.

## Reruns and failures

Installed tools are locked even when an older saved choice selected them.
Tools are rechecked immediately before installation as well. This script does
not request upgrades, start/restart services, migrate Tailscale variants, or
remove tools when deselected. Homebrew automatic update/install-upgrade is
disabled for these installation calls; dependencies required by a new formula
can still be installed by Homebrew. Upstream native installers manage their
own installation files and may have their own update behavior.

The final summary reports **Installed**, **Already present**, **Configured**,
**Configuration current**, **Skipped**, **Failed** or **Manual repair needed**.
Selected install failures produce a nonzero exit after other selected work is
attempted; failed choices are not saved. A pre-existing broken item is locked
and reported for manual repair, rather than attempted as an installation. An
inventory or no-op run can therefore exit successfully while reporting manual
repair needs. Rerun after addressing the failure; working tools will be locked.

Shell changes live in `~/.config/vps-setup/`. Originals are backed up once as
`*.vps-setup.bak`; matching files are untouched. Custom profile lines and the
first existing Bash login profile are preserved. Exported `ZDOTDIR` is honored.
Symlinked files needing updates remain manual. Open a new shell after changes.
`WORKSPACE_DIR` must be absolute and defaults to `~/workspace`.

Saved `ssh`, `screen` and `power` choices are retired with a notice; explicitly
requesting them with `--select` is an error. `MAC_ALWAYS_ON` is ignored.
`MAC_TAILSCALE=0` deselects missing Tailscale before the menu; review the final plan.
Earlier power changes are not undone; any old power-settings backup is retained.

## Manual server checklist

These are guidance only, outside the installation menu. Setup does not inspect
or change them and performs no SSH, Mosh, Screen Sharing, authentication or
network connection probes. `--check` reports local installation state, **not**
a Tailscale address, sign-in status or a guarantee of remote reachability.

- **Remote Login / optional Screen Sharing:** enable in System Settings > General
  > Sharing and choose allowed users. Already working SSH needs no installer step.
- **Power:** choose sleep and power-failure behavior yourself in System Settings
  > Energy. The script neither reads nor changes power settings.
- **New Homebrew Tailscale only:** when ready, follow the official service setup:
  `sudo brew services start tailscale`, then `sudo tailscale up`. Setup installs
  the formula but leaves service startup and sign-in to you. If Tailscale already
  works, keep that installation; these commands are not instructions to migrate it.
- **Accounts:** authenticate GitHub and selected agents separately as needed.
  Existing credentials are preserved; setup does not query authentication status.
- **Restart recovery:** tmux does not preserve live processes through a Mac reboot.
  Save work to disk. FileVault unlock and service startup remain manual operational
  considerations, outside installation verification.

No PostgreSQL, Actions runner, disk monitoring, firewall or Linux service module
runs on the Mac. `DEV_POSTGRES=1` or a nonempty `GH_RUNNER_REPO` produces an error.

## Session shortcuts

After configuring the shortcut and opening a new shell:

| Command / keys | Action |
| --- | --- |
| `t` | Create/attach session `main` |
| `t my-task` | Create/attach a named session; switch to it if already inside tmux |
| Ctrl-b, then d | Detach while its processes continue |
| Ctrl-b, then s | Pick another session |
| `tmux ls` | List sessions |

Task names allow letters, numbers, underscores and hyphens. New sessions start
in `WORKSPACE_DIR`; tmux needs this directory to exist. Mac shortcut setup creates
it. Sessions survive terminal disconnection while the tmux server and Mac keep
running. They do not survive reboot, shutdown, or termination of the tmux server.

## Official guidance and validation

Open [the visual walkthrough](design.html) for a sample menu, dependency graph
and source links alongside each implementation choice. Sample state is illustrative;
run `--check` on your Mac for its actual local inventory.

| Area | Source of truth | Repository choice |
| --- | --- | --- |
| Homebrew | [Installation](https://docs.brew.sh/Installation) | Download official installer to a temporary file with `curl -o "$installer"`, execute `/bin/bash "$installer"`, then remove it; download failure prevents execution |
| Tailscale | [macOS variants](https://tailscale.com/docs/concepts/macos-variants), [daemon setup](https://github.com/tailscale/tailscale/wiki/Tailscaled-on-macOS) | Formula only when absent; startup/sign-in manual; preserve existing variants |
| Mosh | [Official installation](https://mosh.org/#getting) | Homebrew package; SSH/UDP configuration outside this installer |
| tmux | [Getting started](https://github.com/tmux/tmux/wiki/Getting-Started) | Homebrew package plus this repository's optional `t` helper |
| Git / GitHub CLI | [Git macOS](https://git-scm.com/downloads/mac), [GitHub CLI](https://github.com/cli/cli#installation) | Reuse working commands; otherwise Homebrew |
| Agents | [Codex CLI](https://developers.openai.com/codex/cli), [Claude setup](https://code.claude.com/docs/en/setup) | Official native installers; no Node dependency imposed |
| Runtimes | [nvm v0.40.8](https://github.com/nvm-sh/nvm/tree/v0.40.8), [Bun](https://bun.com/docs/installation) | Optional; fresh nvm defaults to pinned v0.40.8, overridable with `NVM_VERSION`; existing nvm reused |
| Manual settings | [Apple Remote Login](https://support.apple.com/guide/mac-help/mchlp1066/mac), [Screen Sharing](https://support.apple.com/guide/mac-help/mh11848/mac), [Energy](https://support.apple.com/guide/mac-help/mchlp1168/mac) | Instructions only |

The nvm default is shared with Linux, so fresh Linux nvm installations also use
v0.40.8. The locked menu, selection dependencies and backup policy are repository
behavior, not claims of upstream endorsement.

`bash tests/test-macos.sh` runs the real entrypoint with isolated fake installers,
commands and HOME, including a real PTY menu. CI runs it on Linux and macOS
(Apple Bash 3.2), plus shell lint and Linux apt regressions. These tests verify
selection, failure/retry and rerun behavior without installing software or changing
system settings. They do not replace a real installation trial on a spare Mac.
