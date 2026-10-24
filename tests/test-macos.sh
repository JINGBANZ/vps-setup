#!/usr/bin/env bash
# Offline behavioral tests: run the real platform dispatcher and Mac setup
# against fake system tools. No packages, services or power settings are changed.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
test_home="$workdir/User's home"
stub_bin="$workdir/bin"
state="$workdir/state"
mkdir -p "$stub_bin" "$state/packages" "$test_home/.nvm"
printf '%s\n' '# existing customization' > "$test_home/.zshrc"
printf '%s\n' '# existing bash login profile' > "$test_home/.profile"
printf '%s\n' 'nvm() { return 0; }' > "$test_home/.nvm/nvm.sh"

cat > "$stub_bin/uname" <<'EOF'
#!/usr/bin/env bash
echo "${TEST_OS:-Darwin}"
EOF
cat > "$stub_bin/id" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  -u) echo "${TEST_UID:-501}" ;;
  -un) echo tester ;;
  *) exit 98 ;;
esac
EOF
cat > "$stub_bin/xcode-select" <<'EOF'
#!/usr/bin/env bash
[ "${TEST_NO_CLT:-0}" = 0 ]
EOF
cat > "$stub_bin/brew" <<'EOF'
#!/usr/bin/env bash
set -eu
printf 'brew %s\n' "$*" >> "$TEST_STATE/calls"
case "$1" in
  shellenv) echo ':' ;;
  list) [ -f "$TEST_STATE/packages/$3" ] ;;
  install)
    [ "${STUB_PRIVILEGED:-0}" = 0 ] || exit 97
    touch "$TEST_STATE/packages/$3" ;;
  services)
    [ "$2" = start ] && [ "$3" = tailscale ] || exit 96
    [ "${STUB_PRIVILEGED:-0}" = 1 ] || exit 95
    [ "${TEST_SERVICE_FAIL:-0}" = 0 ] || exit 1
    touch "$TEST_STATE/service" ;;
  *) exit 94 ;;
esac
EOF
cat > "$stub_bin/sudo" <<'EOF'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >> "$TEST_STATE/calls"
STUB_PRIVILEGED=1 exec "$@"
EOF
cat > "$stub_bin/launchctl" <<'EOF'
#!/usr/bin/env bash
case "$2" in
  gui/*/homebrew.mxcl.tailscale) [ "${TEST_USER_DAEMON:-0}" = 1 ] ;;
  system/com.tailscale.tailscaled) [ "${TEST_OTHER_DAEMON:-0}" = 1 ] ;;
  system/homebrew.mxcl.tailscale) [ -f "$TEST_STATE/service" ] ;;
  *) exit 93 ;;
esac
EOF
cat > "$stub_bin/pmset" <<'EOF'
#!/usr/bin/env bash
set -eu
if [ "$1 $2" = '-g custom' ]; then
  echo 'Battery Power:'
  echo ' sleep 7'
  echo 'AC Power:'
  printf ' sleep %s\n' "$(cat "$TEST_STATE/sleep" 2>/dev/null || echo 1)"
  printf ' autorestart %s\n' "$(cat "$TEST_STATE/autorestart" 2>/dev/null || echo 0)"
elif [ "$1 $2" = '-g cap' ]; then
  echo 'Capabilities for AC Power:'
  echo ' sleep'
  [ "${TEST_NO_AUTORESTART:-0}" = 1 ] || echo ' autorestart'
elif [ "$1" = -c ]; then
  [ "${STUB_PRIVILEGED:-0}" = 1 ] || exit 92
  printf 'power %s %s\n' "$2" "$3" >> "$TEST_STATE/calls"
  echo "$3" > "$TEST_STATE/$2"
else
  exit 91
fi
EOF
cat > "$stub_bin/tmux" <<'EOF'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$@" >> "$TEST_STATE/tmux-calls"
case "$1" in
  -V) echo "tmux test" ;;
  has-session) [ -f "$TEST_STATE/session" ] ;;
  new-session) touch "$TEST_STATE/session" ;;
  attach|switch-client) ;;
  *) exit 90 ;;
esac
EOF
for cmd in git gh mosh node bun claude codex; do
  printf '#!/bin/sh\nprintf "%%s\\n" "stub version"\n' > "$stub_bin/$cmd"
done
# These must never be reached on the macOS path, even when present on PATH.
for cmd in apt-get getent systemctl ufw curl; do
  cat > "$stub_bin/$cmd" <<'EOF'
#!/usr/bin/env bash
echo "Forbidden command: $0" >> "$TEST_STATE/forbidden"
exit 89
EOF
done
chmod +x "$stub_bin"/*

# HOME here is the subprocess's genuine isolated user home, never the caller's.
run_setup() {
  env HOME="$test_home" PATH="$stub_bin:$PATH" TEST_STATE="$state" \
    NVM_DIR="$test_home/.nvm" XDG_CONFIG_HOME= ZDOTDIR="$test_home" \
    WORKSPACE_DIR="$test_home/dev \$(touch SHOULD_NOT_EXIST)" SUDO_USER= \
    GH_RUNNER_REPO= DEV_POSTGRES=0 \
    LOGFILE="$state/setup.log" "$@" /bin/bash "$REPO_ROOT/setup.sh" --select "${TEST_SELECT:-tailscale,ssh,mosh,tmux,shortcut,git,gh,codex,claude,screen,power}" --yes \
    > "$state/output" 2>&1
}

run_setup || { cat "$state/output"; fail 'fresh Mac setup'; }
[ ! -f "$state/forbidden" ] || fail 'macOS ran Linux tools or a network installer'
[ -f "$state/service" ] || fail 'Tailscale was not started as a system service'
[ "$(cat "$state/sleep")" = 0 ] || fail 'AC sleep not disabled'
[ "$(cat "$state/autorestart")" = 1 ] || fail 'power recovery not enabled'
[ -d "$test_home/dev \$(touch SHOULD_NOT_EXIST)" ] || fail 'workspace not created'
[ ! -f "$test_home/.bash_profile" ] || fail 'existing .profile was shadowed'
grep -qx '# existing customization' "$test_home/.zshrc" || fail 'zsh customization lost'
grep -qx '# existing bash login profile' "$test_home/.profile" || fail 'bash customization lost'
grep -q 'sleep 1' "$test_home/.config/vps-setup/power-settings-before.txt" || fail 'no power backup'
/bin/bash -n "$test_home/.config/vps-setup/tmux.sh" || fail 'generated tmux syntax'
if grep -qx EOF "$test_home/.config/vps-setup/tmux.sh"; then
  fail 'heredoc delimiter leaked into generated shell code'
fi

snapshot() {
  cksum "$test_home/.zshrc" "$test_home/.zprofile" "$test_home/.bashrc" \
    "$test_home/.profile" "$test_home/".*.vps-setup.bak "$test_home/.config/vps-setup/"*
}
before="$(snapshot)"
mkdir -p "$state/before"
cp "$test_home/.config/vps-setup/"* "$state/before/"
cp "$test_home/.zshrc" "$test_home/.zprofile" "$test_home/.bashrc" "$test_home/.profile" "$state/before/"
: > "$state/calls"
run_setup || fail 'repeat setup'
if [ "$(snapshot)" != "$before" ]; then
  for file in "$test_home/.zshrc" "$test_home/.zprofile" "$test_home/.bashrc" \
    "$test_home/.profile" "$test_home/.config/vps-setup/"*; do
    diff -u "$state/before/$(basename "$file")" "$file" || true
  done
  cat "$state/output"
  fail 'repeat setup changed shell config or backup'
fi
if grep -Eq '^brew (install|services)|^power |^sudo ' "$state/calls"; then
  fail 'repeat setup reinstalled packages or rewrote power settings'
fi

# Execute generated snippets with nounset, unusual paths, and no TMUX variable.
env HOME="$test_home" PATH="$stub_bin:$PATH" TEST_STATE="$state" \
  /bin/bash -uc '. "$HOME/.config/vps-setup/env.sh"; unset TMUX; t build-task' \
  || fail 'generated bash shortcut'
grep -Fqx "$test_home/dev \$(touch SHOULD_NOT_EXIST)" "$state/tmux-calls" \
  || fail 'workspace was split or evaluated as shell code'
[ ! -e SHOULD_NOT_EXIST ] || fail 'workspace executed a command substitution'
: > "$state/tmux-calls"
env HOME="$test_home" PATH="$stub_bin:$PATH" TEST_STATE="$state" \
  /bin/bash -uc '. "$HOME/.config/vps-setup/env.sh"; TMUX=inside; t build-task' \
  || fail 'switching an existing tmux session'
grep -qx switch-client "$state/tmux-calls" || fail 'nested tmux session instead of switch'
if env HOME="$test_home" PATH="$stub_bin:$PATH" TEST_STATE="$state" \
  /bin/bash -uc '. "$HOME/.config/vps-setup/env.sh"; t invalid:name' 2>/dev/null; then
  fail 'invalid tmux target accepted'
fi
if command -v zsh >/dev/null 2>&1; then
  env HOME="$test_home" PATH="$stub_bin:$PATH" TEST_STATE="$state" \
    zsh -fuc '. "$HOME/.config/vps-setup/env.sh"; unset TMUX; t zsh-task' \
    || fail 'generated zsh shortcut'
fi

for reason in TEST_UID=0 MAC_ALWAYS_ON=invalid MAC_TAILSCALE=invalid \
  WORKSPACE_DIR=relative GH_RUNNER_REPO=owner/repo DEV_POSTGRES=1 TEST_OS=FreeBSD; do
  if run_setup "$reason"; then fail "expected rejection for $reason"; fi
done

mkdir -p "$test_home/Applications/Tailscale.app"
if run_setup; then fail 'GUI plus loaded system service conflict accepted'; fi
: > "$state/calls"
run_setup MAC_TAILSCALE=0 MAC_ALWAYS_ON=0 || fail 'explicit opt-outs'
if grep -Eq '^sudo |^brew (install --formula tailscale|services)' "$state/calls"; then
  fail 'opt-outs still changed privileged settings or Tailscale'
fi
rm -rf "$test_home/Applications/Tailscale.app"
run_setup TEST_NO_AUTORESTART=1 || fail 'Mac without autorestart capability'
grep -q 'Automatic power-on is not exposed' "$state/output" || fail 'missing capability warning'

run_args() {
  env HOME="$test_home" PATH="$stub_bin:$PATH" TEST_STATE="$state" \
    NVM_DIR="$test_home/.nvm" XDG_CONFIG_HOME= ZDOTDIR="$test_home" SUDO_USER= \
    GH_RUNNER_REPO= DEV_POSTGRES=0 /bin/bash "$REPO_ROOT/setup.sh" "$@" \
    > "$state/output" 2>&1
}

# Inventory and plans must not mutate even a partly configured host.
before="$(snapshot)"
: > "$state/calls"
run_args --check || fail 'read-only inventory'
run_args --select node,bun --dry-run || fail 'read-only plan'
[ "$(snapshot)" = "$before" ] || fail 'inspection wrote configuration'
if grep -Eq '^sudo |^brew (install|services)|^power ' "$state/calls"; then fail 'inspection performed a mutation'; fi
if run_args --select postgres --yes; then fail 'unsupported Mac component'; fi
if run_args --yes; then fail 'implicit unattended defaults'; fi
run_args --select none --yes || fail 'empty explicit selection'
[ "$(snapshot)" = "$before" ] || fail 'select none modified configuration'

# Existing GUI and user daemons are reused; an incompatible second service is not installed.
rm -f "$state/service"
mkdir -p "$test_home/Applications/Tailscale.app"
: > "$state/calls"
run_setup || fail 'existing GUI should be reused'
if grep -Eq '^brew services|^sudo .*services' "$state/calls"; then fail 'GUI reuse started a competing daemon'; fi
grep -q 'reuse gui installation' "$state/output" || fail 'GUI not explained in plan'
rm -rf "$test_home/Applications/Tailscale.app"
run_setup TEST_USER_DAEMON=1 || fail 'user daemon reuse'
run_setup TEST_OTHER_DAEMON=1 || fail 'upstream daemon reuse'
if run_setup TEST_USER_DAEMON=1 TEST_OTHER_DAEMON=1; then fail 'multiple daemon conflict accepted'; fi
if run_setup TEST_SERVICE_FAIL=1; then fail 'service failure ignored'; fi
run_setup || fail 'retry after service failure'

# Changed workspace updates only the helper; original backups and unrelated lines survive.
before_backup="$(cksum "$test_home/.zshrc.vps-setup.bak")"
TEST_SELECT=shortcut run_setup WORKSPACE_DIR="$test_home/other workspace" || fail 'workspace change'
grep -Fq 'other' "$test_home/.config/vps-setup/tmux.sh" || fail 'workspace not updated'
[ "$(cksum "$test_home/.zshrc.vps-setup.bak")" = "$before_backup" ] || fail 'original backup overwritten'
grep -qx '# existing customization' "$test_home/.zshrc" || fail 'customizations lost on update'

# A user's symlinked dotfiles must not be replaced or edited indirectly.
mv "$test_home/.zshrc" "$test_home/custom-zshrc"
ln -s "$test_home/custom-zshrc" "$test_home/.zshrc"
printf '# symlink customization\n' > "$test_home/custom-zshrc"
TEST_SELECT=codex run_setup || fail 'symlinked profile'
[ -L "$test_home/.zshrc" ] || fail 'profile symlink replaced'
[ "$(cat "$test_home/custom-zshrc")" = '# symlink customization' ] || fail 'symlink target edited'
grep -q 'Keeping symlink' "$state/output" || fail 'missing manual profile guidance'

# Exercise the actual menu in a PTY: dependency additions and cancellation.
env HOME="$test_home" PATH="$stub_bin:$PATH" TEST_STATE="$state" \
  NVM_DIR="$test_home/.nvm" XDG_CONFIG_HOME= ZDOTDIR="$test_home" SUDO_USER= \
  python3 "$REPO_ROOT/tests/test-macos-menu.py" "$REPO_ROOT/setup.sh"

# Missing tools are installed only when selected; failures are retryable.
cat > "$stub_bin/mosh" <<'EOF'
#!/usr/bin/env bash
[ -f "$TEST_STATE/packages/mosh" ] || exit 1
echo 'mosh test'
EOF
rm -f "$state/packages/mosh"
: > "$state/calls"
TEST_SELECT=codex run_setup || fail 'deselected missing tool'
if grep -q '^brew install' "$state/calls"; then fail 'installed deselected mosh'; fi
TEST_SELECT=mosh run_setup TEST_NO_CLT=1 && fail 'missing CLT accepted for package install'
TEST_SELECT=mosh run_setup || fail 'select missing mosh'
grep -q '^brew install --formula mosh$' "$state/calls" || fail 'selected mosh was not installed'
: > "$state/calls"
TEST_SELECT=mosh run_setup || fail 'repeat selected mosh'
if grep -q '^brew install' "$state/calls"; then fail 'reinstalled mosh'; fi

# Independent native agents: make both missing, select only Codex, fail then retry.
for cmd in codex claude; do
  cat > "$stub_bin/$cmd" <<'EOF'
#!/usr/bin/env bash
[ -f "$TEST_STATE/packages/$(basename "$0")" ] || exit 1
echo 'agent test'
EOF
done
rm -f "$state/packages/codex" "$state/packages/claude"
cat > "$stub_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf 'download %s\n' "$*" >> "$TEST_STATE/calls"
[ "${TEST_DOWNLOAD_FAIL:-0}" = 0 ] || exit 22
case "$*" in
  *chatgpt.com/codex/install.sh*) printf 'touch "$TEST_STATE/packages/codex"\n' ;;
  *bun.com/install*) printf 'touch "$TEST_STATE/packages/bun"\n' ;;
  *) echo 'Unexpected native installer' >&2; exit 88 ;;
esac
EOF
chmod +x "$stub_bin"/*
if TEST_SELECT=codex run_setup TEST_DOWNLOAD_FAIL=1; then fail 'failed selected agent reported success'; fi
TEST_SELECT=codex run_setup || { cat "$state/output"; fail 'retry selected agent'; }
[ -f "$state/packages/codex" ] || fail 'Codex missing after retry'
[ ! -f "$state/packages/claude" ] || fail 'unselected Claude installed'
: > "$state/calls"
TEST_SELECT=codex run_setup || fail 'agent rerun'
if grep -q '^download ' "$state/calls"; then fail 'native agent reinstalled'; fi

# Independent project runtimes; Node selection must not pull in Bun, or vice versa.
for cmd in node bun; do
  cat > "$stub_bin/$cmd" <<'EOF'
#!/usr/bin/env bash
[ -f "$TEST_STATE/packages/$(basename "$0")" ] || exit 1
echo 'runtime test'
EOF
done
cat > "$test_home/.nvm/nvm.sh" <<'EOF'
nvm() {
  printf 'nvm %s\n' "$*" >> "$TEST_STATE/calls"
  if [ "$1" = install ]; then touch "$TEST_STATE/packages/node"; fi
}
EOF
rm -f "$state/packages/node" "$state/packages/bun"
: > "$state/calls"
TEST_SELECT=node run_setup || fail 'Node-only install'
[ -f "$state/packages/node" ] && [ ! -f "$state/packages/bun" ] || fail 'Node installed Bun'
rm -f "$state/packages/node"
: > "$state/calls"
TEST_SELECT=bun run_setup || fail 'Bun-only install'
[ -f "$state/packages/bun" ] && [ ! -f "$state/packages/node" ] || fail 'Bun installed Node'
if grep -q '^nvm install' "$state/calls"; then fail 'Bun installed nvm/Node'; fi

# Signed-in Tailscale reports its assigned address without relogging or exposing peer JSON.
cat > "$stub_bin/tailscale" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  status) printf '{"BackendState":"Running","SecretTestMarker":"not for display"}\n' ;;
  ip) echo 100.101.102.103 ;;
  *) echo 'Unexpected Tailscale mutation' >&2; exit 1 ;;
esac
EOF
cat > "$stub_bin/plutil" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
echo Running
EOF
chmod +x "$stub_bin"/*
run_args --check || fail 'connected inventory'
grep -q 'Screen Sharing address: 100.101.102.103' "$state/output" || fail 'assigned address not reported'
if grep -q SecretTestMarker "$state/output"; then fail 'raw Tailscale status leaked'; fi

echo 'PASS: Mac onboarding, selections, read-only plans, retries, reruns, shell preservation and service reuse'
