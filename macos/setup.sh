#!/usr/bin/env bash
# Compatibility entry point; onboarding is shared with Linux.
set -euo pipefail
[ "$(uname -s)" = Darwin ] || { echo 'macOS required' >&2; exit 1; }
exec /bin/bash "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/setup.sh" "$@"
