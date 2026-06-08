#!/usr/bin/env bash
#
# bootstrap.sh — one-command remote installer for vps-setup.
#
# Lets a fresh box run the whole setup without cloning by hand:
#
#   curl -fsSL https://raw.githubusercontent.com/JINGBANZ/vps-setup/main/bootstrap.sh | sudo bash
#
# It downloads the repo (tarball, with a git fallback) into a temp dir and runs
# setup.sh from it. setup.sh and its modules are the real logic; this file just
# fetches them — the same "tiny bootstrap loader" pattern the Claude/rustup
# installers use.
#
# Env vars are forwarded to setup.sh, but sudo scrubs the environment by
# default, so set them *after* sudo:
#
#   curl -fsSL .../bootstrap.sh | sudo SSH_PORT=2222 bash
#
# The whole body lives in a function called on the last line: if the connection
# drops mid-download, a partial file defines the function but never runs it,
# rather than executing a truncated script.
set -euo pipefail

REPO="${VPS_SETUP_REPO:-JINGBANZ/vps-setup}"
REF="${VPS_SETUP_REF:-main}"

main() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT

  echo "==> Fetching $REPO@$REF"
  local tarball="https://github.com/$REPO/archive/refs/heads/$REF.tar.gz"
  # Tarball downloads need tar; fall back to git when it's missing rather than
  # piping into a nonexistent tar.
  if command -v tar >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
    curl -fsSL "$tarball" | tar -xz -C "$tmp" --strip-components=1
  elif command -v tar >/dev/null 2>&1 && command -v wget >/dev/null 2>&1; then
    wget -qO- "$tarball" | tar -xz -C "$tmp" --strip-components=1
  elif command -v git >/dev/null 2>&1; then
    git clone --depth 1 --branch "$REF" "https://github.com/$REPO.git" "$tmp"
  else
    echo "Need git, or tar plus one of curl/wget, to download $REPO." >&2
    exit 1
  fi

  if [ ! -f "$tmp/setup.sh" ]; then
    echo "setup.sh not found in $REPO@$REF — wrong ref or unexpected layout?" >&2
    exit 1
  fi

  echo "==> Running setup.sh"
  # Already privileged (run under sudo/root); setup.sh's own SUDO logic handles
  # the rest. Env vars set by the caller flow through unchanged.
  bash "$tmp/setup.sh" "$@"
}

main "$@"
