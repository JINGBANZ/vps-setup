#!/usr/bin/env bash
# Source in CI: fetch the exact upstream runtime, not an installer or Node build.
set -euo pipefail
NVM_TEST_SCRIPT="$(mktemp)"
export NVM_TEST_SCRIPT
curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.8/nvm.sh -o "$NVM_TEST_SCRIPT"
test "$(shasum -a 256 "$NVM_TEST_SCRIPT" | awk '{print $1}')" = a64806abf6aab85c456f9ffa2a3be737e35c3a1e6ac99a44ea20c69bdc923467
