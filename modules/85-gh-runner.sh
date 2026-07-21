#!/usr/bin/env bash
# 85-gh-runner.sh — GitHub Actions self-hosted runner, registered to one repo
# and managed as a systemd service (via the runner's own svc.sh).
#
# Opt-in: does nothing unless GH_RUNNER_REPO=owner/repo is set. Registration
# needs a short-lived token minted by an authed `gh` with admin on that repo;
# on a box where gh isn't authed yet, mint one elsewhere and pass GH_RUNNER_TOKEN.
#
# Security model: workflow jobs execute arbitrary repo code on this box. The
# runner therefore runs as a dedicated user with no sudo and deliberately NO
# docker group membership (docker access is root-equivalent). Register PRIVATE
# repos only — on a public repo, a fork PR is a stranger running code here.
[ -n "${_VPS_COMMON_LOADED:-}" ] || { echo "run via setup.sh" >&2; exit 1; }

GH_RUNNER_REPO="${GH_RUNNER_REPO:-}"
# Per-host default name: registering a SECOND VPS to the same repo without setting
# GH_RUNNER_NAME must not collide, because `--replace` (below) evicts an existing runner
# of the same name — two hosts both named "vps" would take turns knocking each other
# offline. The shared LABEL is intentional, though: that's exactly how several runners
# form one `runs-on: vps` pool.
GH_RUNNER_NAME="${GH_RUNNER_NAME:-vps-$(hostname -s 2>/dev/null || echo host)}"
GH_RUNNER_LABELS="${GH_RUNNER_LABELS:-vps}"   # target with `runs-on: vps`
GH_RUNNER_USER="ghrunner"
GH_RUNNER_DIR="/opt/actions-runner"

# Run a command as the runner user, from the current directory. HOME must point
# at that user's home, or config.sh scribbles dotfiles under the invoking user's.
# runuser covers the root path (fresh boxes often have no sudo; SUDO="" there).
_runner_do() {
  if [ -z "$SUDO" ]; then
    runuser -u "$GH_RUNNER_USER" -- env HOME="/home/$GH_RUNNER_USER" "$@"
  else
    sudo -u "$GH_RUNNER_USER" env HOME="/home/$GH_RUNNER_USER" "$@"
  fi
}

if [ -z "$GH_RUNNER_REPO" ]; then
  skip "GitHub Actions runner (opt-in: set GH_RUNNER_REPO=owner/repo)"
elif $SUDO test -f "$GH_RUNNER_DIR/.runner"; then
  # Already registered — but a prior run may have registered (config.sh) and then failed at
  # svc.sh, which would leave the runner permanently offline if we simply skipped here every
  # time. So verify the service is installed AND running, and repair it if not. (To change
  # repo/name/labels instead, first: cd $GH_RUNNER_DIR && sudo ./svc.sh uninstall && sudo
  # ./config.sh remove, then re-run.)
  _svc_name="$($SUDO cat "$GH_RUNNER_DIR/.service" 2>/dev/null || true)"
  if [ -n "$_svc_name" ] && systemctl is-active --quiet "$_svc_name" 2>/dev/null; then
    skip "GitHub Actions runner (registered and running in $GH_RUNNER_DIR)"
  else
    log "GitHub Actions runner registered but service not running — repairing"
    if (cd "$GH_RUNNER_DIR" \
          && { $SUDO test -f .service || $SUDO ./svc.sh install "$GH_RUNNER_USER" >/dev/null; } \
          && $SUDO ./svc.sh start >/dev/null); then
      ok "GitHub Actions runner service (re)started"
    else
      warn "GitHub runner: service repair failed — check 'cd $GH_RUNNER_DIR && sudo ./svc.sh status'"
    fi
  fi
else
  log "Installing GitHub Actions runner for $GH_RUNNER_REPO"

  _gh_runner_token="${GH_RUNNER_TOKEN:-}"
  if [ -z "$_gh_runner_token" ] && have gh && gh auth status >/dev/null 2>&1; then
    _gh_runner_token="$(gh api "repos/$GH_RUNNER_REPO/actions/runners/registration-token" \
      -X POST --jq .token 2>/dev/null || true)"
  fi

  case "$(uname -m)" in
    x86_64)  _gh_runner_arch=x64 ;;
    aarch64) _gh_runner_arch=arm64 ;;
    *)       _gh_runner_arch="" ;;
  esac
  # One fetch of the release metadata: it carries both the version tag and, in the
  # release notes, each asset's published SHA-256 (used below to verify the download).
  _gh_runner_rel="$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest || true)"
  _gh_runner_ver="$(printf '%s' "$_gh_runner_rel" | sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p')"

  # Soft-fail like the other optional installers: a runner is a nice-to-have,
  # baseline provisioning must still complete.
  if [ -z "$_gh_runner_token" ]; then
    warn "GitHub runner: no registration token (need authed gh with admin on $GH_RUNNER_REPO, or GH_RUNNER_TOKEN) — skipping"
  elif [ -z "$_gh_runner_arch" ] || [ -z "$_gh_runner_ver" ]; then
    warn "GitHub runner: unsupported arch '$(uname -m)' or release lookup failed — skipping"
  else
    _gh_runner_tgz="$(mktemp)"
    # Expected hash GitHub publishes in the release notes, tagged per asset with a stable
    # marker (`<!-- BEGIN SHA linux-x64 -->`); used to verify the download below.
    _gh_runner_sha="$(printf '%s' "$_gh_runner_rel" \
      | grep -o "BEGIN SHA linux-${_gh_runner_arch} -->[0-9a-f]\{64\}" | sed 's/.*-->//')"

    # The download gets its own guard: under setup.sh's `set -euo pipefail` a bare failing
    # curl would abort the whole provisioning run, but this optional installer must only
    # soft-fail (see the token/arch checks above).
    if ! curl -fsSL -o "$_gh_runner_tgz" \
         "https://github.com/actions/runner/releases/download/v${_gh_runner_ver}/actions-runner-linux-${_gh_runner_arch}-${_gh_runner_ver}.tar.gz"; then
      rm -f "$_gh_runner_tgz"
      warn "GitHub runner: tarball download failed — skipping install"
    # Verify the SHA-256 — defense in depth over the HTTPS transport, catching a corrupted or
    # tampered artifact before we run its installer as root.
    elif [ -n "$_gh_runner_sha" ] \
       && ! printf '%s  %s\n' "$_gh_runner_sha" "$_gh_runner_tgz" | sha256sum -c --quiet >/dev/null 2>&1; then
      # Mismatch: don't unpack or run the installer from an artifact we can't trust.
      rm -f "$_gh_runner_tgz"
      warn "GitHub runner: SHA-256 mismatch on downloaded tarball — skipping install"
    else
      [ -n "$_gh_runner_sha" ] \
        || warn "GitHub runner: no published SHA-256 found in release notes — proceeding on HTTPS trust only"

      id -u "$GH_RUNNER_USER" >/dev/null 2>&1 \
        || $SUDO useradd --create-home --shell /bin/bash "$GH_RUNNER_USER"
      $SUDO install -d -o "$GH_RUNNER_USER" -g "$GH_RUNNER_USER" "$GH_RUNNER_DIR"

      chmod 0644 "$_gh_runner_tgz"   # mktemp is 0600; the runner user must read it
      (cd "$GH_RUNNER_DIR" && _runner_do tar -xzf "$_gh_runner_tgz")
      rm -f "$_gh_runner_tgz"

      # .NET runtime deps (libicu & friends) the runner needs; root-only, apt-based.
      # installdependencies.sh shells out to apt itself, so route it through the same
      # non-interactive env as lib/common.sh's apt_get: $SUDO scrubs the exported
      # DEBIAN_FRONTEND/NEEDRESTART_MODE, and without them needrestart/debconf can block
      # on a prompt that never gets a TTY in the `curl | sudo bash` install path.
      (cd "$GH_RUNNER_DIR" \
        && $SUDO env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a ./bin/installdependencies.sh >/dev/null)

      # config.sh + svc.sh in `if` conditions so a failure soft-fails (warns) instead of
      # aborting provisioning under `set -e`. If config.sh succeeds but svc.sh fails, the
      # .runner file exists and a re-run repairs the service via the branch near the top.
      if (cd "$GH_RUNNER_DIR" && _runner_do ./config.sh --unattended --replace \
            --url "https://github.com/$GH_RUNNER_REPO" --token "$_gh_runner_token" \
            --name "$GH_RUNNER_NAME" --labels "$GH_RUNNER_LABELS"); then
        # svc.sh writes and enables the systemd unit, running jobs as the dedicated user.
        if (cd "$GH_RUNNER_DIR" && $SUDO ./svc.sh install "$GH_RUNNER_USER" >/dev/null \
              && $SUDO ./svc.sh start >/dev/null); then
          ok "runner '$GH_RUNNER_NAME' registered to $GH_RUNNER_REPO (labels: $GH_RUNNER_LABELS)"
        else
          warn "GitHub runner: registered but service setup failed — re-run setup.sh to retry"
        fi
      else
        warn "GitHub runner: config.sh failed — skipping"
      fi
    fi
  fi
fi
