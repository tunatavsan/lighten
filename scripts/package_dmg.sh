#!/usr/bin/env bash

set -euo pipefail

fail() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)" || fail "Cannot resolve repository root."
readonly ROOT_DIR
readonly APP_NAME="Lighten"
readonly DIST_DIR="$ROOT_DIR/dist"
readonly APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
readonly STAGING_DIR="$DIST_DIR/dmg-staging"

main() {
  local version
  local dmg
  local identity
  local signature_details

  [[ $# -eq 0 ]] || fail "Usage: $(basename "$0")"

  "$ROOT_DIR/scripts/package_app.sh" release
  version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_BUNDLE/Contents/Info.plist")"
  dmg="$DIST_DIR/$APP_NAME-$version.dmg"

  /bin/rm -rf "$STAGING_DIR" "$dmg"
  /bin/mkdir -p "$STAGING_DIR"
  /usr/bin/ditto "$APP_BUNDLE" "$STAGING_DIR/$APP_NAME.app"
  /bin/ln -s /Applications "$STAGING_DIR/Applications"
  /usr/bin/hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$STAGING_DIR" -fs APFS -format ULFO "$dmg"
  /bin/rm -rf "$STAGING_DIR"

  signature_details="$(/usr/bin/codesign -dvv "$APP_BUNDLE" 2>&1)" || fail "Cannot inspect app signature."
  identity="$(printf '%s\n' "$signature_details" | awk -F= '$1 == "Authority" && !found { print $2; found = 1 }')"
  if [[ -n "$identity" ]]; then
    /usr/bin/codesign --force --timestamp --sign "$identity" "$dmg"
  fi

  /usr/bin/hdiutil verify -quiet "$dmg"
  printf 'dmg: %s\n' "$dmg"
  printf 'sha256: %s\n' "$(/usr/bin/shasum -a 256 "$dmg" | awk '{ print $1 }')"
}

main "$@"
