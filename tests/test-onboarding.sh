#!/usr/bin/env bash
# Both platform adapters run against isolated installer commands.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
/bin/bash "$REPO_ROOT/tests/test-macos.sh"
python3 "$REPO_ROOT/tests/test-linux-onboarding.py"
