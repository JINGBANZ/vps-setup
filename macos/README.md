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

Setup installs Homebrew if needed, git, tmux, mosh, gh, nvm/Node LTS, Bun,
Claude Code and Codex. It reuses this repo's official runtime and agent
installers. Optional agent/Bun downloads can fail with warnings; rerun to retry.
It adds the `t` shortcut and PATH/nvm loading to zsh and bash startup files,
preserving existing customizations. `ZDOTDIR` is honored if exported to setup.

By default it disables computer sleep **on AC power**, enables automatic restart
after power failure when `pmset` reports support, and runs the Homebrew
`tailscale` **formula** as a system LaunchDaemon. It does not install an editor.
The original power settings are saved to
`~/.config/vps-setup/power-settings-before.txt`; use them to restore your chosen
values in System Settings > Energy or with `sudo pmset -c KEY VALUE`.

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
SSH (TCP 22) and Screen Sharing (TCP 5900) ports. No home-router port forwarding
is needed. These macOS services can also be reachable on your local LAN;
Tailscale installation alone does not restrict them to the tailnet.

## Daily use

Replace the username/IP with your mini's account and `tailscale ip -4` output:

```bash
ssh YOUR_MAC_USER@100.x.y.z
t my-task
cd ~/workspace/your-repo
codex                          # or claude
```

Detach with **Ctrl-b, then d**. You can close your laptop and later reconnect
with SSH and `t my-task`. Use **Ctrl-b, then s** to switch tasks. Task names may
contain letters, numbers, underscores and hyphens. Your workspace directory is
created during setup; spaces and apostrophes in its path are supported.

Install your laptop's **public** SSH key in the mini's `~/.ssh/authorized_keys`
for key-based login. Keep the private key on your laptop. Use `chmod 700 ~/.ssh`
and `chmod 600 ~/.ssh/authorized_keys` on the mini, then test a second login
before changing any authentication settings.

For desktop access from another Mac, open the **Screen Sharing** app and enter
the mini's Tailscale IP. Authenticate with the mini's account. Closing Screen
Sharing disconnects the viewer; avoid logging the Mac user out if you want GUI
applications to keep running. Desktop responsiveness depends on network latency
and the mini's internet upload speed.

## Unattended operation and recovery

- The Homebrew Tailscale daemon starts at system boot after the disk is unlocked,
  before a GUI user logs in. The regular macOS Tailscale app requires a login
  session. Setup refuses to replace a detected GUI or other daemon installation;
  migrate it locally or set `MAC_TAILSCALE=0` to leave it alone. Do not run both.
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
MAC_ALWAYS_ON=0 bash setup.sh       # leave current power settings unchanged
MAC_TAILSCALE=0 bash setup.sh       # leave an existing Tailscale install alone

sudo brew services info tailscale
sudo tailscale status
pmset -g custom
```

Running setup again fills in missing tools and refreshes managed shell snippets.
It does not upgrade installed packages or intentionally restart an already
running Tailscale service. Homebrew formulae do not self-update: use
`brew update` and `brew upgrade` during a maintenance window, then check the
Tailscale service. A loaded service is not proof of authenticated connectivity;
check `tailscale status` and an actual remote connection.

## References

- [Tailscale macOS variants](https://tailscale.com/docs/concepts/macos-variants)
- [Tailscaled on macOS, including Homebrew service setup](https://github.com/tailscale/tailscale/wiki/Tailscaled-on-macOS)
- [Apple: Remote Login](https://support.apple.com/guide/mac-help/mchlp1066/mac)
- [Apple: Screen Sharing](https://support.apple.com/guide/mac-help/mh11848/mac)
- [Apple: Remote Management and kickstart limitations](https://support.apple.com/guide/remote-desktop/apd8b1c65bd/mac)
- [Apple: FileVault over SSH](https://support.apple.com/guide/security/sec8447f5049/web)
- [Codex CLI](https://developers.openai.com/codex/cli)
- [Claude Code setup](https://code.claude.com/docs/en/setup)
