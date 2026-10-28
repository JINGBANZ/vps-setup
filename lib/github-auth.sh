#!/usr/bin/env bash

on_github_authenticate() {
  if [ -n "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]; then
    printf 'Keeping GitHub authentication supplied by the environment.\n'
    gh auth status --active --hostname github.com || return 1
  elif gh auth status --active --hostname github.com >/dev/null 2>&1; then
    printf 'Keeping existing GitHub authentication.\n'
  else
    if [ "$PLATFORM" = macos ]; then
      printf 'Unlock the Mac default Keychain in this terminal before signing in.\n'
      printf 'Enter its password at the macOS prompt; setup does not record it.\n'
      security unlock-keychain || return 1
    fi
    # Unlocking may make an existing login available in this SSH session.
    if ! gh auth status --active --hostname github.com >/dev/null 2>&1; then
      printf 'Follow GitHub CLI prompts. Over SSH, open the displayed URL on your own computer.\n'
      gh auth login --hostname github.com --git-protocol https --web || return 1
    fi
  fi
  gh auth setup-git --hostname github.com || return 1
  gh auth status --active --hostname github.com || return 1
  if [ "$PLATFORM" = macos ] && [ -z "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]; then
    printf 'Storage check: (keyring) means Keychain; a configuration file path means plaintext storage.\n'
    printf 'If Keychain locks again, run: security unlock-keychain\n'
  fi
}

on_offer_github_login() {
  on_tool gh >/dev/null || return 0
  # Check before rendering the optional step. Never prompt or log credentials
  # during this probe; valid stored and environment logins need no sign-in.
  if gh auth status --active --hostname github.com </dev/null >/dev/null 2>&1; then
    return 0
  fi
  printf '\nOptional GitHub HTTPS authentication (existing credentials are kept).\n' >&4
  if ! ui_gum confirm 'Set up GitHub authentication now?' --affirmative 'Sign in' --negative Skip --default=false --timeout=0; then
    printf 'GitHub authentication skipped.\n' >&4
    return 0
  fi
  # Keep password/device-code prompts on the terminal, outside Linux's tee log.
  # Ctrl-C cancels the optional command without changing the installation result.
  trap ':' INT
  if (trap 'exit 130' INT; on_github_authenticate) <&3 >&4 2>&4; then
    printf 'GitHub authentication and Git credential helper verified.\n' >&4
  else
    printf 'GitHub authentication setup did not finish. Installation results are unchanged.\n' >&4
    printf 'Retry using the steps at https://github.com/JINGBANZ/vps-setup#github-authentication\n' >&4
  fi
  trap 'exit 130' INT
}
