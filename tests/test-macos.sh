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
  has-session) [ -f "$TEST_STATE/session" ] ;;
  new-session) touch "$TEST_STATE/session" ;;
  attach|switch-client) ;;
  *) exit 90 ;;
esac
EOF
for cmd in node bun claude codex; do
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
    MAC_ALWAYS_ON=1 MAC_TAILSCALE=1 GH_RUNNER_REPO= DEV_POSTGRES=0 \
    LOGFILE="$state/setup.log" "$@" /bin/bash "$REPO_ROOT/setup.sh" \
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
    "$test_home/.profile" "$test_home/.config/vps-setup/"*
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
if grep -Eq '^brew install|^power ' "$state/calls"; then
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

for reason in TEST_UID=0 TEST_NO_CLT=1 TEST_USER_DAEMON=1 TEST_OTHER_DAEMON=1 \
  TEST_SERVICE_FAIL=1 MAC_ALWAYS_ON=invalid MAC_TAILSCALE=invalid \
  WORKSPACE_DIR=relative GH_RUNNER_REPO=owner/repo DEV_POSTGRES=1 TEST_OS=FreeBSD; do
  if run_setup "$reason"; then fail "expected rejection for $reason"; fi
done

mkdir -p "$test_home/Applications/Tailscale.app"
if run_setup; then fail 'GUI Tailscale conflict accepted'; fi
: > "$state/calls"
run_setup MAC_TAILSCALE=0 MAC_ALWAYS_ON=0 || fail 'explicit opt-outs'
if grep -Eq '^sudo |^brew (install --formula tailscale|services)' "$state/calls"; then
  fail 'opt-outs still changed privileged settings or Tailscale'
fi
rm -rf "$test_home/Applications/Tailscale.app"
run_setup TEST_NO_AUTORESTART=1 || fail 'Mac without autorestart capability'
grep -q 'Automatic power-on is not exposed' "$state/output" || fail 'missing capability warning'

echo 'PASS: Mac dispatch, user installs, service scope, reruns, shell quoting, conflicts and opt-outs'
