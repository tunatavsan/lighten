#!/usr/bin/env bash

set -euo pipefail

fail() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)" || fail "Cannot resolve repository root."
[[ -n "$ROOT_DIR" && "$ROOT_DIR" != "/" && -f "$ROOT_DIR/Package.swift" && -d "$ROOT_DIR/Sources/LightenKit" ]] ||
  fail "Invalid repository root: $ROOT_DIR"
readonly ROOT_DIR
readonly APP_NAME="Lighten"
readonly DIST_DIR="$ROOT_DIR/dist"
readonly SWIFTPM_SCRATCH_DIR="$DIST_DIR/swiftpm-build"
readonly APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
readonly CONTENTS_DIR="$APP_BUNDLE/Contents"
readonly RESOURCES_DIR="$CONTENTS_DIR/Resources"
readonly SOURCE_INFO_PLIST="$ROOT_DIR/Resources/Info.plist"
readonly VERSION_SOURCE="$ROOT_DIR/Sources/LightenKit/LightenVersion.swift"
readonly IDENTITY_SOURCE="$ROOT_DIR/Sources/LightenKit/LightenIdentity.swift"
readonly LOCALIZATION_CATALOG="$ROOT_DIR/Resources/Localizable.xcstrings"
readonly PRIVACY_MANIFEST="$ROOT_DIR/Resources/PrivacyInfo.xcprivacy"
readonly ASSET_CATALOG="$ROOT_DIR/Resources/Assets.xcassets"

usage() {
  printf 'Usage: %s [debug|release]\n' "$(basename "$0")" >&2
}

find_signing_identity() {
  local identities
  local identity

  if ! identities="$(/usr/bin/security find-identity -v -p codesigning)"; then
    fail "Unable to query code-signing identities."
  fi

  if [[ "${LIGHTEN_SIGN_IDENTITY:-}" == "-" ]]; then
    printf '%s\n' "-"
    return
  fi

  if [[ -n "${LIGHTEN_SIGN_IDENTITY:-}" ]]; then
    if ! printf '%s\n' "$identities" | /usr/bin/grep -Fq "\"$LIGHTEN_SIGN_IDENTITY\""; then
      fail "LIGHTEN_SIGN_IDENTITY is not a valid installed code-signing identity."
    fi
    printf '%s\n' "$LIGHTEN_SIGN_IDENTITY"
    return
  fi

  local matching_count
  matching_count="$(printf '%s\n' "$identities" | awk -F'"' '$2 ~ /^(Developer ID Application|Apple Development):/ { count++ } END { print count+0 }')"
  if (( matching_count > 1 )); then
    printf 'warning: %s signing identities found; set LIGHTEN_SIGN_IDENTITY to choose one.\n' "$matching_count" >&2
  fi

  identity="$(printf '%s\n' "$identities" | awk -F'"' '$2 ~ /^Developer ID Application:/ { print $2; exit }')"
  if [[ -z "$identity" ]]; then
    identity="$(printf '%s\n' "$identities" | awk -F'"' '$2 ~ /^Apple Development:/ { print $2; exit }')"
  fi

  if [[ -z "$identity" ]]; then
    printf 'warning: no Developer ID Application or Apple Development identity found; signing ad hoc.\n' >&2
    identity="-"
  fi

  printf '%s\n' "$identity"
}

read_bundle_identity() {
  local plist_identity
  local source_identity

  [[ -f "$IDENTITY_SOURCE" ]] || fail "Identity source is missing: $IDENTITY_SOURCE"
  plist_identity="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SOURCE_INFO_PLIST")" ||
    fail "Unable to read CFBundleIdentifier from Info.plist."
  source_identity="$(sed -nE 's/^[[:space:]]*public[[:space:]]+static[[:space:]]+let[[:space:]]+bundleIdentifier[[:space:]]*=[[:space:]]*"([^"]+)"[[:space:]]*$/\1/p' "$IDENTITY_SOURCE")"
  [[ "$source_identity" =~ ^[A-Za-z0-9.-]+$ ]] || fail "Unable to read bundle identity from $IDENTITY_SOURCE"
  [[ "$plist_identity" == "$source_identity" ]] || fail "Info.plist identity differs from LightenIdentity.bundleIdentifier."
  printf '%s\n' "$plist_identity"
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

verify_package() {
  local configuration="$1"
  local bundle_id="$2"
  local expected_entitlements="$3"
  local actual_id
  local signature_details
  local signed_id
  local kit_bundle="$RESOURCES_DIR/Lighten_LightenKit.bundle"
  local kit_catalog
  local entitlement_file="$DIST_DIR/signed-entitlements.plist"

  for language in en tr; do
    [[ -s "$RESOURCES_DIR/$language.lproj/Localizable.strings" ]] ||
      fail "Missing $language localization in packaged app."
  done
  [[ -s "$RESOURCES_DIR/PrivacyInfo.xcprivacy" ]] || fail "Missing privacy manifest in packaged app."
  [[ -d "$kit_bundle" && ! -L "$kit_bundle" ]] ||
    fail "Missing bundled LightenKit resources in packaged app."
  if [[ -e "$kit_bundle/Contents/Info.plist" || -L "$kit_bundle/Contents/Info.plist" ]]; then
    [[ -f "$kit_bundle/Contents/Info.plist" && ! -L "$kit_bundle/Contents/Info.plist" ]] ||
      fail "Unsafe bundled LightenKit Info.plist in packaged app."
    [[ -d "$kit_bundle/Contents/Resources" && ! -L "$kit_bundle/Contents/Resources" ]] ||
      fail "Missing nested LightenKit resource directory in packaged app."
    kit_catalog="$kit_bundle/Contents/Resources/catalog.json"
  else
    kit_catalog="$kit_bundle/catalog.json"
  fi
  [[ -f "$kit_catalog" && -s "$kit_catalog" && ! -L "$kit_catalog" ]] ||
    fail "Missing bundled Clean catalog in packaged app."
  actual_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$CONTENTS_DIR/Info.plist")" ||
    fail "Packaged Info.plist has no bundle identity."
  [[ "$actual_id" == "$bundle_id" ]] || fail "Packaged Info.plist identity changed."

  signature_details="$(/usr/bin/codesign -dvv "$APP_BUNDLE" 2>&1)" || fail "Cannot inspect app signature."
  signed_id="$(printf '%s\n' "$signature_details" | awk -F= '$1 == "Identifier" { print $2 }')"
  [[ "$signed_id" == "$bundle_id" ]] || fail "Signed identifier differs from Info.plist."
  [[ "$signature_details" =~ flags=0x[0-9a-f]+\([^\)]*runtime ]] || fail "Hardened runtime is absent."
  /usr/bin/codesign -d --entitlements :- "$APP_BUNDLE" >"$entitlement_file" 2>/dev/null ||
    fail "Cannot inspect signed entitlements."
  /usr/bin/python3 - "$expected_entitlements" "$entitlement_file" <<'PY' ||
import plistlib
import sys

with open(sys.argv[1], "rb") as source, open(sys.argv[2], "rb") as signed:
    if plistlib.load(source) != plistlib.load(signed):
        raise SystemExit(1)
PY
    fail "Signed entitlements differ from selected entitlements."
  if [[ "$configuration" == "debug" ]]; then
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.get-task-allow' "$entitlement_file" 2>/dev/null)" == "true" ]] ||
      fail "Debug signature must permit debugging."
  else
    if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.get-task-allow' "$entitlement_file" >/dev/null 2>&1; then
      fail "Release signature must not permit debugging."
    fi
    [[ -d "$DIST_DIR/$APP_NAME.dSYM" ]] || fail "Release dSYM is missing."
  fi
  /bin/unlink "$entitlement_file"
  /usr/bin/codesign --verify --deep --strict "$APP_BUNDLE" || fail "App signature verification failed."
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
  local bundle_id

  if [[ $# -gt 1 ]] || [[ "$configuration" != "debug" && "$configuration" != "release" ]]; then
    usage
    exit 64
  fi

  [[ -f "$SOURCE_INFO_PLIST" ]] || fail "Info.plist is missing: $SOURCE_INFO_PLIST"
  [[ -f "$LOCALIZATION_CATALOG" ]] || fail "String catalog is missing: $LOCALIZATION_CATALOG"
  [[ -f "$PRIVACY_MANIFEST" ]] || fail "Privacy manifest is missing: $PRIVACY_MANIFEST"
  bundle_id="$(read_bundle_identity)"

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
  [[ ! -L "$DIST_DIR" ]] || fail "dist must not be a symbolic link."
  /bin/mkdir -p "$DIST_DIR"
  [[ ! -L "$SWIFTPM_SCRATCH_DIR" ]] || fail "SwiftPM scratch must not be a symbolic link."
  /bin/rm -rf "$APP_BUNDLE" "$DIST_DIR/$APP_NAME.dSYM"

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

  if [[ "$configuration" == "release" ]]; then
    if [[ -d "$build_dir/$APP_NAME.dSYM" ]]; then
      /bin/cp -R "$build_dir/$APP_NAME.dSYM" "$DIST_DIR/"
    else
      /usr/bin/xcrun dsymutil "$executable" -o "$DIST_DIR/$APP_NAME.dSYM"
    fi
  fi

  if [[ -d "$ASSET_CATALOG" ]]; then
    compile_assets
  fi

  /usr/bin/xattr -cr "$APP_BUNDLE"
  /usr/bin/codesign \
    --force \
    --options runtime \
    --timestamp \
    --identifier "$bundle_id" \
    --entitlements "$entitlements" \
    --sign "$signing_identity" \
    "$APP_BUNDLE"

  verify_package "$configuration" "$bundle_id" "$entitlements"
  /usr/bin/codesign -dvv "$APP_BUNDLE"
}

main "$@"
