# Mac mini as an always-on development machine

The mini keeps your repos, runtimes and agent sessions. Your laptop connects
over SSH and can disconnect while work continues inside tmux. Screen Sharing
is available for occasional desktop access. VS Code is not needed.

## First setup, on the mini

1. Finish macOS setup and sign in to your normal administrator account. Connect
   to your home Wi-Fi or Ethernet. Wi-Fi works; Ethernet avoids wireless dropouts
   and is preferable when testing recovery after a reboot.
2. In Terminal, run `xcode-select --install` if Command Line Tools are missing.
   Finish Apple's installer before continuing. Use a macOS version supported by
   [Homebrew](https://docs.brew.sh/Installation).
3. Clone this repo and run **without sudo**:

   ```bash
   git clone https://github.com/JINGBANZ/vps-setup.git
   cd vps-setup
   bash setup.sh
   ```

   Alternatively, download the bootstrap first so installer prompts have a
   terminal available:

   ```bash
   curl -fsSL https://raw.githubusercontent.com/JINGBANZ/vps-setup/main/bootstrap.sh -o /tmp/vps-setup-bootstrap.sh
   bash /tmp/vps-setup-bootstrap.sh
   ```

4. Open a new terminal, or run `source ~/.config/vps-setup/env.sh`.

## Interactive onboarding and reruns

The first run inventories tools and configuration before offering a numbered
selection menu. Toggle numbers (for example `3,4`), or use `all`, `none`, or
`defaults`. Press Enter to review the plan, then type `apply` to proceed. Nothing
is installed or configured before this confirmation. The last successful
selection is remembered as plain data; every run checks the machine again.

| ID | Component | Initial default |
| --- | --- | --- |
| `tailscale` | Private network and startup configuration | Selected |
| `ssh` | Remote Login / SSH setup guidance | Selected |
| `mosh` | Terminal connection that tolerates Wi-Fi changes | Selected |
| `tmux` | Sessions that survive laptop disconnects | Selected |
| `shortcut` | `t NAME` session helper | Selected |
| `git`, `gh` | Git and GitHub CLI; independent choices | Selected |
| `codex`, `claude` | Native terminal agents; independent choices | Selected |
| `node`, `bun` | Project runtimes; independent choices | Off |
| `screen` | Built-in Screen Sharing guidance | Selected |

The shortcut adds tmux as a dependency; Mosh adds Remote Login guidance.
Homebrew is installed only when a selected missing package requires it. Existing
usable tools are reused, including tools outside Homebrew. Detection includes
versions/paths, Tailscale variant and readable authentication status, loaded
Sharing services. A loaded service still needs its allowed
users and actual remote access verified. Unreadable auth state is shown as
`unknown`, not treated as signed out.

```bash
bash setup.sh --check                         # read-only inventory and address
bash setup.sh --select mosh,tmux,codex --dry-run
bash setup.sh --select tailscale,mosh,tmux,shortcut,codex,claude,screen --yes
bash setup.sh --select none --yes             # no changes
```

`--yes` requires an explicit `--select` list. Without a terminal, use this
explicit automation mode or a read-only command. Sudo may still request your
password for selected system changes. These flags apply only to macOS; Linux
rejects them rather than silently starting provisioning.

Deselecting skips a component; it does not uninstall it, remove existing
shortcuts. Reruns do not deliberately upgrade tools,
restart a loaded service, or repeat successful native installs. A failed
selected agent/runtime produces a nonzero exit after the remaining steps;
rerunning fills in the missing tool. Upgrades are separate maintenance work.

Shell changes are kept in `~/.config/vps-setup/` and sourced by zsh and bash.
Files are replaced only when their content differs; original modified files
are backed up once as `*.vps-setup.bak`. Existing custom lines and the first
existing Bash login profile are preserved. Exported `ZDOTDIR` is honored.
Symlinked profiles are left intact with a warning: add
`source ~/.config/vps-setup/env.sh` to their target yourself if needed.
Authentication is left to you; the Mac installer does not capture it in a log.

Power settings are entirely manual. In **System Settings > Energy**, review
**Prevent automatic sleeping when the display is off** and restart after power
failure if available. The installer does not read or modify power settings.
Display sleep can remain enabled while the computer stays awake.

If an earlier version changed power settings, this update does not undo them.
Review them manually; the earlier `power-settings-before.txt` backup remains
available if it was created. Saved selections migrate away from the
removed component with a notice; an explicit `--select power` is rejected.
The obsolete `MAC_ALWAYS_ON` variable is ignored.

A new Tailscale install uses the Homebrew **formula** and a system LaunchDaemon.
Existing GUI apps, user daemons and other installations are kept with startup
review guidance. Competing installed/loaded variants block the selected
Tailscale step before provisioning. Migration must be deliberate and local;
the script never stops your existing connection to install another variant.

See [the visual design](design.html) for network and session graphs. Its
onboarding simulation uses example data; `--check` reports the real machine.

## Enable SSH and optional Screen Sharing

Open **System Settings > General > Sharing** on the mini:

- Turn on **Remote Login** and set **Allow access for: Only these users**, adding
  your account. This is the Mac's built-in SSH server.
- Turn on **Screen Sharing** if you want desktop access, again allowing only
  your account. Apple's Screen Sharing and Remote Management are separate
  options and cannot both be enabled simultaneously.

These settings remain manual: Apple protects them, and `kickstart` cannot
enable Screen Sharing on modern macOS. Setup does not bypass privacy controls,
change the SSH port/password policy, or claim these services are already on.

Install the normal [Tailscale app](https://tailscale.com/download) on your laptop
and sign in to the same tailnet. On the mini:

```bash
sudo tailscale up
tailscale ip -4
gh auth login
claude
codex
```

Each agent needs its own sign-in. Authenticate interactively after setup, so
authentication links/codes do not enter the setup log. If browser callbacks
are awkward over SSH, do the first sign-in locally or through Screen Sharing.

Use ordinary macOS SSH over Tailscale; `tailscale up --ssh` is not needed.
Configure your tailnet access rules to permit your laptop to reach the mini's
SSH (TCP 22), Mosh (UDP 60000–61000), and Screen Sharing (TCP 5900) ports,
as well as the relevant host firewall permissions. Home-router port forwarding
is normally unnecessary. These macOS services can also be reachable on your local LAN;
Tailscale installation alone does not restrict them to the tailnet.

## Addresses and direct connections

After sign-in, Tailscale automatically assigns the mini a stable private IP.
The script does not choose an IP. Re-run `bash setup.sh --check` after
`sudo tailscale up` to display a verified address. If CLI status needs elevated
permission, use `sudo tailscale status` and `sudo tailscale ip -4` yourself.
With MagicDNS enabled, the machine name also works. Your laptop must be in the
same authorized tailnet, independently of either Mac's Apple ID.

Connections initially use a relay while Tailscale tries NAT traversal. A direct
connection becomes available when the two networks allow a working UDP path;
it does not require the same Wi-Fi. Restrictive NAT/firewalls may keep it relayed.
Both paths are encrypted and use the same Tailscale address. Check the actual
route with `tailscale ping YOUR_MINI_NAME` or `tailscale status`.

Screen Sharing itself is built into macOS and does not need this script.
Tailscale supplies remote network reachability; macOS Sharing enables desktop
access. Screen Sharing can work while the display is off, provided the computer
is awake. System sleep suspends agent work; wake-on-network is not a substitute
for an awake server.

## Daily use

Replace the username/IP with your mini's account and `tailscale ip -4` output:

```bash
mosh YOUR_MAC_USER@100.x.y.z
t my-task
cd ~/workspace/your-repo
codex                          # or claude
```

Detach with **Ctrl-b, then d**. You can close your laptop and later reconnect
with Mosh and `t my-task`. Mosh uses SSH to authenticate, then UDP for the
terminal. Install Mosh on the laptop too; keep SSH for file transfers, port
forwarding and fallback access. A running Mosh client can resume after Wi-Fi
roaming; closing that client requires a new connection and tmux reattachment. Use **Ctrl-b, then s** to switch tasks. Task names may
contain letters, numbers, underscores and hyphens. Your workspace directory is
created during setup; spaces and apostrophes in its path are supported.

Install your laptop's **public** SSH key in the mini's `~/.ssh/authorized_keys`
for key-based login. Keep the private key on your laptop. Use `chmod 700 ~/.ssh`
and `chmod 600 ~/.ssh/authorized_keys` on the mini, then test a second login
before changing any authentication settings.

For desktop access from another Mac, open the **Screen Sharing** app and enter
the mini's Tailscale IP or MagicDNS machine name. Authenticate with the mini's
local macOS username/password; the two Macs may use different Apple IDs. Closing Screen
Sharing disconnects the viewer; avoid logging the Mac user out if you want GUI
applications to keep running. Desktop responsiveness depends on network latency
and the mini's internet upload speed.

## Unattended operation and recovery

- The Homebrew Tailscale daemon starts at system boot after the disk is unlocked,
  before a GUI user logs in. The regular macOS Tailscale app requires a login
  session. Setup reuses a detected GUI or other daemon installation and reports that its
  startup mode needs review; migrate locally if you need pre-login service. Do not run both.
- Keep FileVault enabled. On Apple silicon with macOS 26+, Apple supports
  unlocking FileVault over SSH after a restart when Remote Login is enabled and
  the network is available. The mini's own Tailscale daemon cannot provide the
  network path before its startup disk is unlocked. For remote recovery, use a
  VPN on the home router or a separate always-on Tailscale subnet router to reach
  the mini's LAN IP. Test your actual Wi-Fi/Ethernet configuration; ordinary
  logged-in Wi-Fi access does not prove pre-unlock access works. Keep a local
  recovery option until that test succeeds.
- tmux preserves sessions across disconnects, **not crashes or reboots**. Use
  application-specific `launchd` services for workloads that must start again
  automatically; setup does not auto-launch agents or restore running tasks.
- Test SSH and Screen Sharing from a phone hotspot, then test after a reboot
  without a local GUI login. Test reconnecting after a router restart as well.
- For a trusted unattended mini, consider disabling its Tailscale device-key
  expiry in the admin console, while keeping access restricted to your devices.
- Keep macOS, Homebrew and your agents updated. Back up your workspace. A UPS
  should power the mini **and** router if you need continuity through outages.

The script does not disable FileVault, enable automatic login, change Wi-Fi
credentials, open public router ports, or change your macOS firewall/update
preferences. Linux's UFW, fail2ban, disk guard, optional PostgreSQL and Actions
runner modules are not run on macOS. Setting `DEV_POSTGRES` or `GH_RUNNER_REPO`
on macOS produces an error instead of silently skipping the requested service.

## Settings and checks

```bash
WORKSPACE_DIR="$HOME/Dev Projects" bash setup.sh
bash setup.sh --select codex,claude --dry-run
bash setup.sh --check              # read-only installed state and assigned IP

sudo brew services info tailscale
sudo tailscale status
pmset -g custom
```

Running setup again fills in missing tools and refreshes managed shell snippets.
It does not deliberately upgrade installed packages or restart an already
loaded Tailscale service. `MAC_TAILSCALE=0` deselects Tailscale before the
menu; review the final plan. Homebrew formulae do not self-update: use
`brew update` and `brew upgrade` during a maintenance window, then check the
Tailscale service. A loaded service is not proof of authenticated connectivity;
check `tailscale status` and an actual remote connection.

## References

- [Tailscale connection types](https://tailscale.com/docs/reference/connection-types)
- [Tailscale IP assignment](https://tailscale.com/docs/concepts/ip-and-dns-addresses)
- [Mosh](https://mosh.org/)
- [tmux sessions](https://github.com/tmux/tmux/wiki/Getting-Started)
- [Tailscale macOS variants](https://tailscale.com/docs/concepts/macos-variants)
- [Tailscaled on macOS, including Homebrew service setup](https://github.com/tailscale/tailscale/wiki/Tailscaled-on-macOS)
- [Apple: Remote Login](https://support.apple.com/guide/mac-help/mchlp1066/mac)
- [Apple: Screen Sharing](https://support.apple.com/guide/mac-help/mh11848/mac)
- [Apple: Remote Management and kickstart limitations](https://support.apple.com/guide/remote-desktop/apd8b1c65bd/mac)
- [Apple: FileVault over SSH](https://support.apple.com/guide/security/sec8447f5049/web)
- [Codex CLI](https://developers.openai.com/codex/cli)
- [Claude Code setup](https://code.claude.com/docs/en/setup)
