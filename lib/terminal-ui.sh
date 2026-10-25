#!/usr/bin/env bash
# Interactive terminal UI dependency. No downloads or terminal changes on source.
# v2.0.2 fails our Space-toggle PTY regression; keep this tested release pinned.
# Digests: official release assets at github.com/charmbracelet/gum/releases/tag/v0.17.0.
UI_GUM_VERSION=0.17.0
UI_GUM_BIN=''
UI_GUM_TMP=''

ui_cleanup() {
  if [ -n "$UI_GUM_TMP" ]; then rm -rf "$UI_GUM_TMP"; UI_GUM_TMP=''; fi
}

ui_gum_asset() {
  local os arch
  os="$(uname -s)"; arch="$(uname -m)"
  case "$os:$arch" in
    Darwin:arm64) UI_GUM_SHA=e2a4b8596efa05821d8c58d0c1afbcd7ad1699ba69c689cc3ff23a4a99c8b237 ;;
    Darwin:x86_64) UI_GUM_SHA=cd66576aeebe6cd19c771863c7e8d696e0e1d5387d1e7075666baa67c2052e53 ;;
    Linux:aarch64|Linux:arm64) arch=arm64; UI_GUM_SHA=b0b9ed95cbf7c8b7073f17b9591811f5c001e33c7cfd066ca83ce8a07c576f9c ;;
    Linux:x86_64) UI_GUM_SHA=69ee169bd6387331928864e94d47ed01ef649fbfe875baed1bbf27b5377a6fdb ;;
    *) return 1 ;;
  esac
  UI_GUM_ARCHIVE="gum_${UI_GUM_VERSION}_${os}_${arch}"
}

ui_gum_version_ok() {
  local version
  version="$("$1" --version 2>/dev/null)" || return 1
  case "$version" in "gum version v$UI_GUM_VERSION"|"gum version v$UI_GUM_VERSION "*) return 0 ;; *) return 1 ;; esac
}

ui_gum_download() {
  local actual member
  ui_gum_asset || return 1
  UI_GUM_TMP="$(mktemp -d)" || return 1
  printf 'Loading menu...\n' >&2
  curl -fsSL --connect-timeout 10 --max-time 60 \
    "https://github.com/charmbracelet/gum/releases/download/v$UI_GUM_VERSION/$UI_GUM_ARCHIVE.tar.gz" \
    -o "$UI_GUM_TMP/gum.tar.gz" || return 1
  if command -v shasum >/dev/null 2>&1; then
    actual="$(shasum -a 256 "$UI_GUM_TMP/gum.tar.gz")" || return 1
  elif command -v sha256sum >/dev/null 2>&1; then
    actual="$(sha256sum "$UI_GUM_TMP/gum.tar.gz")" || return 1
  else return 1; fi
  [ "${actual%% *}" = "$UI_GUM_SHA" ] || return 1
  # Extract only the expected binary from the verified archive; never install it.
  member="$UI_GUM_ARCHIVE/gum"
  tar -xOf "$UI_GUM_TMP/gum.tar.gz" "$member" > "$UI_GUM_TMP/gum" || return 1
  chmod 700 "$UI_GUM_TMP/gum" || return 1
  ui_gum_version_ok "$UI_GUM_TMP/gum" || return 1
  UI_GUM_BIN="$UI_GUM_TMP/gum"
}

ui_prepare() {
  local candidate
  [ "${TERM:-dumb}" != dumb ] && [ -n "${TERM:-}" ] || return 1
  [ -t 3 ] && [ -t 4 ] || return 1
  candidate="$(command -v gum || true)"
  if [ -n "$candidate" ] && ui_gum_version_ok "$candidate"; then UI_GUM_BIN="$candidate"; return 0; fi
  if ui_gum_download; then return 0; fi
  ui_cleanup
  printf 'Unable to prepare the verified Gum keyboard menu.\n' >&2
  return 1
}

ui_gum() {
  # Selections go to stdout; terminal input/rendering stay on the caller's TTY.
  "$UI_GUM_BIN" "$@" <&3 2>&4
}
