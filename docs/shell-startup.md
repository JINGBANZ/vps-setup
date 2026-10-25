# Shell startup contract

Installation inventory checks local presence and versions. Usability is a
separate contract, tested from fresh shells with a minimal initial PATH.
Setup never connects to your laptop or server to test access.

| Usage | Initialization | Supported behavior |
| --- | --- | --- |
| Terminal / interactive SSH, Bash or Zsh | Login/interactive profiles | Installed tools, nvm and optional `t` helper |
| `ssh HOST 'COMMAND'`, Bash | Managed hook at the beginning of `.bashrc` | Same environment, before existing non-interactive return guards |
| `ssh HOST 'COMMAND'`, Zsh / Mosh startup | Managed hook in `.zshenv` | Same environment, no startup output or automatic tmux attachment |
| Bash background script | Explicit `BASH_ENV` pointing to managed `env.sh` | Same environment, including nvm's Node/npm and executable shebangs |
| A service, cron, or another program executing a binary directly | Explicit environment or absolute executable path | Does not assume an interactive profile was read |

For batch Bash jobs, configure the job's invocation explicitly:

```bash
BASH_ENV="$HOME/.config/vps-setup/env.sh" /bin/bash /absolute/path/job.sh
```

For a service manager, use the account's absolute path in its environment
configuration. Setup does not set a global `BASH_ENV`, edit jobs/services, or
claim to configure shells such as Fish. `bash --norc`, `zsh -f`, and user code
that later overrides PATH intentionally bypass or supersede initialization.
The interactive `t` attachment needs a terminal, for example `ssh -t HOST 't task'`.

## Managed environment

- Homebrew uses its official `brew shellenv sh` output: `bin`, `sbin`, manual/info
  paths and Homebrew variables. A shell-local guard avoids repeated calls unless
  its directories have been removed from PATH. Discovery specifies `bash`
  explicitly rather than guessing the executing shell.
- Native agent and Bun locations are added without duplicate PATH entries.
- If nvm is installed and not already loaded, its official `nvm.sh` initializes
  Node for the current shell. This supports subprocesses and `#!/usr/bin/env node`
  scripts as well as direct `node`, `npm`, `npx`, and `nvm` commands. It follows
  nvm's current/default selection instead of freezing a version path at setup time.
- The optional tmux helper is loaded as a function definition. Loading the
  environment does not create, attach or switch sessions.

Unlike PR #27's PATH-only remote hook, this loads nvm when installed in remote
command shells too. That adds nvm's normal initialization cost. Its initialization
stdout is suppressed to keep remote protocols clean; errors remain on stderr.
Repeated sourcing does not reload an already-defined nvm function or reset a
version selected with `nvm use`.

Existing custom profile text is preserved. The managed Bash hook moves ahead of
early-return guards; old managed hooks are removed so reruns do not duplicate it.
Changed files get one original backup, matching content is not rewritten, and
symlinked files needing changes stay locked for manual integration. Exported
`ZDOTDIR` is honored.

## Sources and regression coverage

| Source of truth | Behavior covered |
| --- | --- |
| [Zsh startup files](https://zsh.sourceforge.io/Doc/Release/Files.html), [Zsh introduction](https://zsh.sourceforge.io/Intro/intro_3.html) | `.zshenv` for non-interactive commands; silent initialization |
| [Bash startup files](https://www.gnu.org/software/bash/manual/html_node/Bash-Startup-Files.html) | Login/interactive profiles, SSH `.bashrc`, explicit `BASH_ENV` for batch jobs |
| [Homebrew shellenv](https://docs.brew.sh/Manpage#shellenv-shell-) | Complete upstream environment and an explicit shell argument |
| [nvm v0.40.8](https://github.com/nvm-sh/nvm/tree/v0.40.8#install--update-script) | Official loading/activation behavior and non-interactive initialization |
| [Mosh usage / FAQ](https://mosh.org/) | SSH launches `mosh-server` through the remote shell's PATH |

`tests/test-shell-startup.py` uses real Bash/Zsh and the SHA-256-verified upstream
nvm script, with local Node and tool stubs. It covers startup modes, executable
Node shebangs, default/version changes, silence, custom paths, Bash guards,
symlinks and reruns. macOS CI additionally tests actual Homebrew `shellenv`.

`tests/test-ssh-startup.py` runs only in a disposable Ubuntu CI container. It
creates temporary Bash/Zsh test accounts and an sshd bound to loopback, then
tests actual SSH command discovery, login shells, a real Mosh server startup,
and the real tmux shortcut over SSH. It does not test Tailscale routing, Mosh's
UDP transport, or production-machine connectivity.

Run the local suite with the verified Gum binary and upstream nvm fixture:

```bash
source tests/prepare-nvm-test.sh
trap 'rm -f "$NVM_TEST_SCRIPT"' EXIT
GUM_TEST_BIN=/path/to/gum-0.17.0 bash tests/test-onboarding.sh
```

New tool integrations should declare their binary paths, initialization needs,
and supported execution modes here, then add startup tests with a minimal PATH.
Do not manually source configuration in a test meant to verify automatic startup.
