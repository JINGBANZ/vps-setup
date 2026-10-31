# Preview service

Host static HTML previews on this machine through private Tailscale links.

Select **Preview service** in onboarding, or run `bash setup.sh --select
preview-service --yes` from a checkout. The component is optional and stays
selectable for configuration reconciliation. `--check` and `--dry-run` do not
install, start services, fetch skill contents, or probe the network.

## Prerequisites and installation

Tailscale must already be running and signed in with a `.ts.net` DNS name.
Setup preserves its credentials and unrelated Serve routes. Enable tailnet HTTPS
if Tailscale requests it, then rerun. It never enables Funnel, changes tailnet
access policies, replaces a Tailscale variant, or opens public firewall ports.
Existing listeners on localhost:8787 or unrelated Serve/Funnel mappings on 8443
stop setup. An existing Funnel route on any port targeting localhost:8787 also
stops setup, including foreground routes, so starting Caddy cannot activate a
previously unavailable public preview backend. A failed apply exits nonzero;
completed installation work remains
available for a rerun, and a discovery file is written only after configuration
succeeds.

Setup installs a pinned, checksum-verified Caddy binary in
`/usr/local/libexec/preview-service/`, separate from any existing Caddy installation.
It creates a non-login service account and a systemd service (Linux) or system
LaunchDaemon (macOS), with boot startup and process restart. Caddy serves only
static files from localhost:8787; its admin API, directory listing, and automatic
HTTPS are disabled. Tailscale Serve owns HTTPS :8443 and its persistent mapping.

The served folder is `/var/lib/preview-service/previews/` on Linux and
`/Library/Application Support/preview-service/previews/` on macOS. The invoking
setup account owns that folder; the service account has read/traverse permission.
One publishing account owns the service on each machine. Configurations and
service binaries remain outside the served folder. Deselecting the component
does not disable it or remove previews. No automatic expiry or cleanup is applied.

On Linux, Tailscale normally runs at boot. On macOS, Caddy starts at boot, but the
GUI Tailscale variants need a login session; setup reports this condition. Both
system-wide and user-local app bundles are supported, including CLI symlinks.
Availability also requires the machine to be awake and booted and Tailscale to
remain authenticated. Setup does not change power, disk-unlock, or login settings.

## Agent discovery and publishing

Setup writes `~/.config/vps-setup/preview-service.json`:

```json
{
  "version": 1,
  "preview_root": "/var/lib/preview-service/previews",
  "base_url": "https://host.tailnet.ts.net:8443",
  "publisher": "/home/user/.local/share/vps-setup/preview-service/skill/scripts/publish.py",
  "skill_revision": "<pinned skills commit>"
}
```

The skill and publisher come from a pinned revision of
[JINGBANZ/skills](https://github.com/JINGBANZ/skills/tree/main/preview-service),
verified before installation. One managed copy is registered at
`~/.agents/skills/preview-service` for Codex and
`~/.claude/skills/preview-service` for Claude Code. Registration works even when
the CLI is installed later; the component does not install either agent itself.
An existing independently installed skill of the same name is preserved and
reported as a conflict. Start a new agent session to discover the skill.

The publisher takes one self-contained UTF-8 HTML file:

```bash
python3 /path/from/config/publish.py --new --task pricing-page-redesign ./mockup.html
python3 /path/from/config/publish.py --task pricing-page-redesign ./revised.html
```

A task has one readable directory. `v1.html`, `v2.html`, etc. are immutable
revisions; `index.html` is the latest published revision. Concurrent publications
serialize within the task. `--new` refuses a name collision; use a more descriptive
name for a different task. The script returns JSON with the latest and revision
URLs only after fetching and comparing their contents over HTTPS. Verification
failure can leave a saved revision and is reported explicitly. If revision
verification fails, the previous latest stays intact; if verification fails after
replacing `index.html`, the new latest remains. It never substitutes a public URL.
Neither the service nor publisher renders HTML to validate its design.

## Security boundary

Only devices allowed by the effective Tailscale policy, including explicit device
sharing, can connect remotely. Local processes can still reach localhost; permitted
viewers can copy files elsewhere. Tailnet membership is not proof of owner-only
access: configure the policy for the intended users/devices separately.

Publish only trusted, self-contained mockups with example data. There is no HTTP
upload API, server-side code execution, or authentication secret in previews.
The publisher rejects symlink files, non-regular inputs, unsafe task names, and
symlink task directories. Caddy refuses dot-path requests. Never copy a repository,
secrets, or runtime logs into the served directory. The publishing account can
write directly to that directory, so this is not a sandbox against a malicious
agent with that account's filesystem access. HTML can execute JavaScript in the
viewer's browser; separate paths are not independent browser security origins.

## Validation

`python3 tests/test-preview-service.py` checks setup boundaries and service
configuration without provisioning a host. Set `PREVIEW_TEST_CADDY` to a verified
Caddy binary to include the loopback smoke test, including Tailscale's forwarded
hostname; CI downloads the pinned binary and runs this on Linux and macOS.
The ordinary onboarding suite covers
selection and dry-run behavior. The skill repository tests revision preservation,
concurrent publication, symlink/path rejection, and verification failures.
Before rollout, verify one real Linux/macOS installation, local-only listening,
authorized laptop access, denied access outside Tailscale, and recovery after a
machine reboot. A source-level test does not prove host networking or boot recovery.
