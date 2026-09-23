#!/usr/bin/env bash

set -euo pipefail

fail() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)" || fail "Cannot resolve repository root."
readonly ROOT_DIR
readonly APP_NAME="Lighten"
readonly SOURCE_APP="$ROOT_DIR/dist/$APP_NAME.app"
readonly INSTALL_DIR="${LIGHTEN_INSTALL_DIR:-/Applications}"
readonly TARGET_APP="$INSTALL_DIR/$APP_NAME.app"
readonly STAGING_APP="$INSTALL_DIR/.$APP_NAME.app.installing"

bundle_id_of() {
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null
}

main() {
  local expected_id
  local installed_binary

  [[ $# -eq 0 ]] || fail "Usage: $(basename "$0")"
  [[ -d "$INSTALL_DIR" && -w "$INSTALL_DIR" ]] || fail "$INSTALL_DIR is not writable by this account."

  if /usr/bin/pgrep -f "^$TARGET_APP/Contents/MacOS/$APP_NAME" >/dev/null; then
    fail "$TARGET_APP is running. Quit it before installing."
  fi

  "$ROOT_DIR/scripts/package_app.sh" release
  expected_id="$(bundle_id_of "$SOURCE_APP")" || fail "Packaged app has no bundle identity."
  /usr/bin/codesign --verify --strict --deep "$SOURCE_APP" || fail "Packaged app signature is invalid."

  if [[ -e "$TARGET_APP" || -L "$TARGET_APP" ]]; then
    [[ -d "$TARGET_APP" && ! -L "$TARGET_APP" ]] || fail "$TARGET_APP is not a regular app bundle."
    [[ "$(bundle_id_of "$TARGET_APP")" == "$expected_id" ]] ||
      fail "$TARGET_APP belongs to a different bundle identity; refusing to replace it."
  fi

  /bin/rm -rf "$STAGING_APP"
  /usr/bin/ditto "$SOURCE_APP" "$STAGING_APP"
  /usr/bin/codesign --verify --strict --deep "$STAGING_APP" || fail "Staged app signature is invalid."
  /bin/rm -rf "$TARGET_APP"
  /bin/mv "$STAGING_APP" "$TARGET_APP"
  /usr/bin/codesign --verify --strict --deep --verbose=1 "$TARGET_APP"

  installed_binary="$TARGET_APP/Contents/MacOS/$APP_NAME"
  printf 'installed: %s\n' "$TARGET_APP"
  printf 'version: %s (%s)\n' \
    "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$TARGET_APP/Contents/Info.plist")" \
    "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$TARGET_APP/Contents/Info.plist")"
  printf 'architectures: %s\n' "$(/usr/bin/lipo -archs "$installed_binary")"
  printf 'sha256: %s\n' "$(/usr/bin/shasum -a 256 "$installed_binary" | awk '{ print $1 }')"
}

main "$@"
