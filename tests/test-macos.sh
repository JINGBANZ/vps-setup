#!/usr/bin/env bash
# Execute the actual Mac entry point with isolated package/system commands.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 "$REPO_ROOT/tests/test-macos-install.py"
