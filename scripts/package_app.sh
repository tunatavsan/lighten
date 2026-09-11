#!/usr/bin/env bash

set -euo pipefail

readonly ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly APP_NAME="Lighten"
readonly BUNDLE_ID="com.tavsn.lighten"
readonly DIST_DIR="$ROOT_DIR/dist"
readonly SWIFTPM_SCRATCH_DIR="$DIST_DIR/swiftpm-build"
readonly APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
readonly CONTENTS_DIR="$APP_BUNDLE/Contents"
readonly RESOURCES_DIR="$CONTENTS_DIR/Resources"
readonly SOURCE_INFO_PLIST="$ROOT_DIR/Resources/Info.plist"
readonly VERSION_SOURCE="$ROOT_DIR/Sources/LightenKit/LightenVersion.swift"
readonly LOCALIZATION_CATALOG="$ROOT_DIR/Resources/Localizable.xcstrings"
readonly PRIVACY_MANIFEST="$ROOT_DIR/Resources/PrivacyInfo.xcprivacy"
readonly ASSET_CATALOG="$ROOT_DIR/Resources/Assets.xcassets"

fail() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

usage() {
  printf 'Usage: %s [debug|release]\n' "$(basename "$0")" >&2
}

find_signing_identity() {
  local identities
  local identity

  if ! identities="$(/usr/bin/security find-identity -v -p codesigning)"; then
    fail "Unable to query code-signing identities."
  fi

  identity="$(printf '%s\n' "$identities" | awk -F'"' '$2 ~ /^Developer ID Application:/ { print $2; exit }')"
  if [[ -z "$identity" ]]; then
    identity="$(printf '%s\n' "$identities" | awk -F'"' '$2 ~ /^Apple Development:/ { print $2; exit }')"
  fi

  if [[ -z "$identity" ]]; then
    fail "No Developer ID Application or Apple Development signing identity was found."
  fi

  printf '%s\n' "$identity"
}

read_versions() {
  local marketing_version
  local build_number

  [[ -f "$VERSION_SOURCE" ]] || fail "Version source is missing: $VERSION_SOURCE"

  marketing_version="$(sed -nE 's/^[[:space:]]*(public[[:space:]]+)?static[[:space:]]+let[[:space:]]+marketing[[:space:]]*=[[:space:]]*"([^"]+)"[[:space:]]*$/\2/p' "$VERSION_SOURCE")"
  build_number="$(sed -nE 's/^[[:space:]]*(public[[:space:]]+)?static[[:space:]]+let[[:space:]]+build[[:space:]]*=[[:space:]]*([0-9]+)[[:space:]]*$/\2/p' "$VERSION_SOURCE")"

  [[ "$marketing_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] ||
    fail "Unable to read a valid marketing version from $VERSION_SOURCE"
  [[ "$build_number" =~ ^[1-9][0-9]*$ ]] ||
    fail "Unable to read a positive build number from $VERSION_SOURCE"

  printf '%s\n%s\n' "$marketing_version" "$build_number"
}

compile_assets() {
  local actool_info_plist="$DIST_DIR/actool-partial-info.plist"
  local actool_arguments=(
    "$ASSET_CATALOG"
    --compile "$RESOURCES_DIR"
    --platform macosx
    --minimum-deployment-target 26.0
    --output-partial-info-plist "$actool_info_plist"
  )

  if [[ -d "$ASSET_CATALOG/AppIcon.appiconset" ]]; then
    actool_arguments+=(--app-icon AppIcon)
  fi

  /usr/bin/xcrun actool "${actool_arguments[@]}"
  [[ -f "$actool_info_plist" ]] || fail "actool did not produce its partial Info.plist."
  /usr/libexec/PlistBuddy -c "Merge $actool_info_plist" "$CONTENTS_DIR/Info.plist"
  /bin/unlink "$actool_info_plist"
}

copy_swiftpm_bundles() {
  local build_dir="$1"
  local bundle

  while IFS= read -r -d '' bundle; do
    /bin/cp -R "$bundle" "$RESOURCES_DIR/"
  done < <(/usr/bin/find "$build_dir" -maxdepth 1 -type d -name '*.bundle' -print0)
}

main() {
  local configuration="${1:-debug}"
  local build_dir
  local executable
  local entitlements
  local marketing_version
  local build_number
  local signing_identity
  local versions
  local build_arguments

  if [[ $# -gt 1 ]] || [[ "$configuration" != "debug" && "$configuration" != "release" ]]; then
    usage
    exit 64
  fi

  [[ -f "$SOURCE_INFO_PLIST" ]] || fail "Info.plist is missing: $SOURCE_INFO_PLIST"
  [[ -f "$LOCALIZATION_CATALOG" ]] || fail "String catalog is missing: $LOCALIZATION_CATALOG"
  [[ -f "$PRIVACY_MANIFEST" ]] || fail "Privacy manifest is missing: $PRIVACY_MANIFEST"

  if [[ "$configuration" == "debug" ]]; then
    entitlements="$ROOT_DIR/Resources/Lighten-dev.entitlements"
  else
    entitlements="$ROOT_DIR/Resources/Lighten.entitlements"
  fi
  [[ -f "$entitlements" ]] || fail "Entitlements file is missing: $entitlements"

  versions="$(read_versions)"
  marketing_version="$(printf '%s\n' "$versions" | sed -n '1p')"
  build_number="$(printf '%s\n' "$versions" | sed -n '2p')"
  signing_identity="$(find_signing_identity)"
  build_arguments=(-c "$configuration" --scratch-path "$SWIFTPM_SCRATCH_DIR")
  if [[ "$configuration" == "release" ]]; then
    build_arguments+=(--arch arm64 --arch x86_64)
  fi

  cd "$ROOT_DIR"
  /bin/rm -rf "$DIST_DIR"
  /bin/mkdir -p "$DIST_DIR"

  swift build "${build_arguments[@]}"
  build_dir="$(swift build "${build_arguments[@]}" --show-bin-path)"
  executable="$build_dir/$APP_NAME"
  [[ -x "$executable" ]] || fail "Built executable is missing: $executable"

  /bin/mkdir -p "$CONTENTS_DIR/MacOS" "$RESOURCES_DIR"
  /bin/cp "$executable" "$CONTENTS_DIR/MacOS/$APP_NAME"
  /bin/chmod +x "$CONTENTS_DIR/MacOS/$APP_NAME"
  /bin/cp "$SOURCE_INFO_PLIST" "$CONTENTS_DIR/Info.plist"

  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $marketing_version" "$CONTENTS_DIR/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$CONTENTS_DIR/Info.plist"

  /usr/bin/xcrun xcstringstool compile "$LOCALIZATION_CATALOG" --output-directory "$RESOURCES_DIR"
  /bin/cp "$PRIVACY_MANIFEST" "$RESOURCES_DIR/PrivacyInfo.xcprivacy"
  copy_swiftpm_bundles "$build_dir"
  /bin/rm -rf "$SWIFTPM_SCRATCH_DIR"

  if [[ -d "$ASSET_CATALOG" ]]; then
    compile_assets
  fi

  /usr/bin/xattr -cr "$APP_BUNDLE"
  /usr/bin/codesign \
    --force \
    --options runtime \
    --timestamp \
    --identifier "$BUNDLE_ID" \
    --entitlements "$entitlements" \
    --sign "$signing_identity" \
    "$APP_BUNDLE"

  /usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"
  /usr/bin/codesign -dvv "$APP_BUNDLE"
}

main "$@"
