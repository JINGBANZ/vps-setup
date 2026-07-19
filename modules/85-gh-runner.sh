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
GH_RUNNER_NAME="${GH_RUNNER_NAME:-vps}"
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
  # Already registered. Unregister with `cd $GH_RUNNER_DIR && ./svc.sh uninstall
  # && ./config.sh remove` before re-running to change repo/name/labels.
  skip "GitHub Actions runner (already registered in $GH_RUNNER_DIR)"
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
  _gh_runner_ver="$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest \
    | sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p')"

  # Soft-fail like the other optional installers: a runner is a nice-to-have,
  # baseline provisioning must still complete.
  if [ -z "$_gh_runner_token" ]; then
    warn "GitHub runner: no registration token (need authed gh with admin on $GH_RUNNER_REPO, or GH_RUNNER_TOKEN) — skipping"
  elif [ -z "$_gh_runner_arch" ] || [ -z "$_gh_runner_ver" ]; then
    warn "GitHub runner: unsupported arch '$(uname -m)' or release lookup failed — skipping"
  else
    id -u "$GH_RUNNER_USER" >/dev/null 2>&1 \
      || $SUDO useradd --create-home --shell /bin/bash "$GH_RUNNER_USER"
    $SUDO install -d -o "$GH_RUNNER_USER" -g "$GH_RUNNER_USER" "$GH_RUNNER_DIR"

    _gh_runner_tgz="$(mktemp)"
    curl -fsSL -o "$_gh_runner_tgz" \
      "https://github.com/actions/runner/releases/download/v${_gh_runner_ver}/actions-runner-linux-${_gh_runner_arch}-${_gh_runner_ver}.tar.gz"
    chmod 0644 "$_gh_runner_tgz"   # mktemp is 0600; the runner user must read it
    (cd "$GH_RUNNER_DIR" && _runner_do tar -xzf "$_gh_runner_tgz")
    rm -f "$_gh_runner_tgz"

    # .NET runtime deps (libicu & friends) the runner needs; root-only, apt-based.
    (cd "$GH_RUNNER_DIR" && $SUDO ./bin/installdependencies.sh >/dev/null)

    (cd "$GH_RUNNER_DIR" && _runner_do ./config.sh --unattended --replace \
      --url "https://github.com/$GH_RUNNER_REPO" --token "$_gh_runner_token" \
      --name "$GH_RUNNER_NAME" --labels "$GH_RUNNER_LABELS")

    # svc.sh writes and enables the systemd unit, running jobs as the dedicated user.
    (cd "$GH_RUNNER_DIR" && $SUDO ./svc.sh install "$GH_RUNNER_USER" >/dev/null \
      && $SUDO ./svc.sh start >/dev/null)

    ok "runner '$GH_RUNNER_NAME' registered to $GH_RUNNER_REPO (labels: $GH_RUNNER_LABELS)"
  fi
fi
