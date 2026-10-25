#!/usr/bin/env bash
# CI-only integration: invoke after test-fresh-install.sh in a disposable root
# Ubuntu container. Installs real mosh, using a disposable user configuration.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ "$(id -u)" = 0 ] || { echo 'SKIP: disposable root container required'; exit 0; }
[ -f /usr/sbin/policy-rc.d ] || { echo 'Run test-fresh-install.sh first' >&2; exit 1; }
case "$(uname -s)" in Linux) ;; *) exit 1 ;; esac
onboarding_home="$(mktemp -d)"
trap 'rm -rf "$onboarding_home"' EXIT
# Explicit environment is limited to this child; never repurpose the shell HOME.
timeout 240 env HOME="$onboarding_home" SUDO_USER='' \
  /bin/bash "$REPO_ROOT/setup.sh" --select mosh --yes </dev/null
mosh --version
snapshot="$(find "$onboarding_home" -type f -exec sha256sum {} \; | sort)"
output="$(timeout 30 env HOME="$onboarding_home" SUDO_USER='' \
  /bin/bash "$REPO_ROOT/setup.sh" --select mosh,shell --yes </dev/null)"
printf '%s\n' "$output"
[[ "$output" == *'No changes selected.'* ]]
[ "$snapshot" = "$(find "$onboarding_home" -type f -exec sha256sum {} \; | sort)" ]
echo 'PASS: real selected apt install and unchanged rerun through shared onboarding'
