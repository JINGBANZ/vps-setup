#!/usr/bin/env bash
# Both platforms enter the same onboarding engine.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec /bin/bash "$SCRIPT_DIR/lib/setup.sh" "$@"
