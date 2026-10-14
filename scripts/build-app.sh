#!/bin/bash
# Build the distributable .app. Host-native, ad-hoc signing is the default.
# Optional distribution knobs are intentionally environment/config driven:
#   VERSION=1.2.3                 required when the checkout has no git tag to derive it from
#   UNIVERSAL=1                   arm64 + x86_64 executable
#   SIGNING_IDENTITY="Developer ID Application: ..." HARDENED_RUNTIME=1
#   NOTARIZE=1 plus ONE credential set (credentials are never stored in the repository):
#     NOTARY_PROFILE=<notarytool keychain profile>
#     NOTARY_KEY_PATH=<AuthKey_XXXX.p8> NOTARY_KEY_ID=<key id> [NOTARY_ISSUER_ID=<issuer uuid>]
# See RELEASING.md for the full release procedure.
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="desnotch"
DIST_DIR="${DIST_DIR:-dist}"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null || true)}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo "1")}"
BUNDLE_ID="${BUNDLE_ID:-com.desnotch.app}"
UNIVERSAL="${UNIVERSAL:-0}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
HARDENED_RUNTIME="${HARDENED_RUNTIME:-0}"
ENTITLEMENTS="${ENTITLEMENTS:-scripts/desnotch.entitlements}"
NOTARIZE="${NOTARIZE:-0}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
NOTARY_KEY_PATH="${NOTARY_KEY_PATH:-}"
NOTARY_KEY_ID="${NOTARY_KEY_ID:-}"
NOTARY_ISSUER_ID="${NOTARY_ISSUER_ID:-}"

VENDOR_DIR="$PWD/Sources/DesnotchCore/MediaRemote/Vendor/MediaRemoteAdapter"
VENDOR_MANIFEST="$VENDOR_DIR/VENDOR.sha256"

fail() { echo "error: $*" >&2; exit 1; }

[[ -n "$VERSION" ]] || fail "no VERSION: this checkout has no git tag to derive it from; set VERSION=x.y.z (or run 'git fetch --tags')"
VERSION="${VERSION#v}"
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]] || fail "VERSION must be dotted numeric (got '$VERSION')"
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || fail "BUILD_NUMBER must be positive integer (got '$BUILD_NUMBER')"
[[ "$BUNDLE_ID" =~ ^[A-Za-z0-9.-]+$ && "$BUNDLE_ID" == *.* ]] || fail "BUNDLE_ID must be a stable reverse-DNS identifier (got '$BUNDLE_ID')"
[[ "$UNIVERSAL" == 0 || "$UNIVERSAL" == 1 ]] || fail "UNIVERSAL must be 0 or 1"
[[ "$HARDENED_RUNTIME" == 0 || "$HARDENED_RUNTIME" == 1 ]] || fail "HARDENED_RUNTIME must be 0 or 1"
[[ "$NOTARIZE" == 0 || "$NOTARIZE" == 1 ]] || fail "NOTARIZE must be 0 or 1"

# notarytool credentials: a keychain profile, or an App Store Connect API key.
NOTARY_AUTH=()
if [[ "$NOTARIZE" == 1 ]]; then
  if [[ "$SIGNING_IDENTITY" == "-" || "$HARDENED_RUNTIME" != 1 ]]; then
    fail "NOTARIZE=1 requires Developer ID signing (SIGNING_IDENTITY) and HARDENED_RUNTIME=1"
  fi
  if [[ -n "$NOTARY_PROFILE" ]]; then
    NOTARY_AUTH=(--keychain-profile "$NOTARY_PROFILE")
  elif [[ -n "$NOTARY_KEY_PATH" && -n "$NOTARY_KEY_ID" ]]; then
    [[ -f "$NOTARY_KEY_PATH" ]] || fail "NOTARY_KEY_PATH is not a file: $NOTARY_KEY_PATH"
    NOTARY_AUTH=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID")
    if [[ -n "$NOTARY_ISSUER_ID" ]]; then
      NOTARY_AUTH+=(--issuer "$NOTARY_ISSUER_ID")
    fi
  else
    fail "NOTARIZE=1 requires NOTARY_PROFILE, or NOTARY_KEY_PATH + NOTARY_KEY_ID (+ NOTARY_ISSUER_ID for team keys)"
  fi
fi

verify_vendor() {
  # Hashes are relative to the adapter directory, so run from inside $1.
  [[ -f "$VENDOR_MANIFEST" ]] || fail "vendor manifest missing: $VENDOR_MANIFEST"
  (cd "$1" && shasum -a 256 -c --quiet "$VENDOR_MANIFEST") \
    || fail "vendored MediaRemoteAdapter does not match VENDOR.sha256 ($1)"
}

build_host() {
  echo "==> swift build -c release" >&2
  swift build -c release >&2 || return
  echo ".build/release/$APP_NAME"
}

build_universal() {
  local arch triple scratch binary
  local -a binaries=()
  # Never let a previous universal output leak into this build.
  rm -rf .build-universal
  for arch in arm64 x86_64; do
    triple="$arch-apple-macosx13.0"
    scratch=".build-release-$arch"
    echo "==> swift build -c release --triple $triple" >&2
    swift build -c release --triple "$triple" --scratch-path "$scratch" >&2 || return
    binary="$(find "$scratch" -type f -path '*/release/'"$APP_NAME" -perm -111 -print -quit)"
    [[ -n "$binary" ]] || fail "$arch release binary not found"
    binaries+=("$binary")
  done
  mkdir -p .build-universal
  lipo -create "${binaries[0]}" "${binaries[1]}" -output ".build-universal/$APP_NAME"
  chmod 755 ".build-universal/$APP_NAME"
  echo ".build-universal/$APP_NAME"
}

echo "==> verifying vendored adapter against VENDOR.sha256"
verify_vendor "$VENDOR_DIR"

if [[ "$UNIVERSAL" == 1 ]]; then
  BIN_PATH="$(build_universal)"
  RESOURCE_BUNDLE="$(find .build-release-arm64 -type d -name "${APP_NAME}_DesnotchCore.bundle" -print -quit)"
  archs="$(lipo -archs "$BIN_PATH")"
  [[ "$archs" == *arm64* && "$archs" == *x86_64* ]] || fail "universal binary has architectures '$archs'"
else
  BIN_PATH="$(build_host)"
  RESOURCE_BUNDLE=".build/release/${APP_NAME}_DesnotchCore.bundle"
fi

ADAPTER_SRC="$RESOURCE_BUNDLE/MediaRemoteAdapter"
[[ -x "$BIN_PATH" ]] || fail "release binary not found at $BIN_PATH"
[[ -d "$ADAPTER_SRC" ]] || fail "adapter resources not found at $ADAPTER_SRC"
[[ -f "$ADAPTER_SRC/mediaremote-adapter.pl" ]] || fail "adapter script missing"
[[ -d "$ADAPTER_SRC/MediaRemoteAdapter.framework" ]] || fail "adapter framework missing"
[[ -f "$ADAPTER_SRC/LICENSE-mediaremote-adapter" ]] || fail "adapter license missing"
[[ -f LICENSE && -f NOTICE.md ]] || fail "LICENSE or NOTICE.md missing from the repository root"

RESOURCES="$APP_BUNDLE/Contents/Resources"
echo "==> assembling $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
rm -f "$DIST_DIR/$APP_NAME-notarize.zip"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$RESOURCES"
cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp -R "$ADAPTER_SRC" "$RESOURCES/MediaRemoteAdapter"
cp Assets/AppIcon.icns "$RESOURCES/AppIcon.icns"
# Redistribution notices: this app's license, third-party notices, and the BSD-3-Clause
# license text that the vendored adapter requires binary redistributions to reproduce.
cp LICENSE "$RESOURCES/LICENSE"
cp NOTICE.md "$RESOURCES/NOTICE.md"
cp "$ADAPTER_SRC/LICENSE-mediaremote-adapter" "$RESOURCES/LICENSE-mediaremote-adapter"

# Prove the copy that will ship is the pinned upstream build, then drop the manifest:
# signing rewrites the framework's Mach-O, so it could never match inside the bundle.
verify_vendor "$RESOURCES/MediaRemoteAdapter"
rm -f "$RESOURCES/MediaRemoteAdapter/VENDOR.sha256"

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>desnotch</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIconFile</key><string>AppIcon.icns</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSCalendarsUsageDescription</key><string>desnotch shows your next meeting in the notch pill.</string>
    <key>NSCalendarsFullAccessUsageDescription</key><string>desnotch shows your next meeting in the notch pill.</string>
    <key>NSRemindersUsageDescription</key><string>desnotch shows and completes your next due reminder.</string>
    <key>NSRemindersFullAccessUsageDescription</key><string>desnotch shows, creates, and completes reminders you choose to manage.</string>
    <key>NSMicrophoneUsageDescription</key><string>desnotch listens while you hold the voice shortcut and turns what you say into a command on this Mac. Audio is never saved or sent anywhere.</string>
    <key>NSSpeechRecognitionUsageDescription</key><string>desnotch uses on-device speech recognition to turn what you say into text. Nothing is sent to Apple.</string>
    <key>NSAppleEventsUsageDescription</key><string>When you turn on "Let the agent control this Mac" and approve an AppleScript on the voice card, desnotch runs it to control the app it names.</string>
    <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP_BUNDLE/Contents/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Print :CFBundleIconFile" "$APP_BUNDLE/Contents/Info.plist" >/dev/null

SIGN_ARGS=(--force --sign "$SIGNING_IDENTITY")
if [[ "$HARDENED_RUNTIME" == 1 ]]; then
  SIGN_ARGS+=(--options runtime)
fi
if [[ "$SIGNING_IDENTITY" != "-" ]]; then
  # A secure timestamp is required for notarization and keeps the signature valid after
  # the certificate expires. Ad-hoc signatures have no certificate to timestamp.
  SIGN_ARGS+=(--timestamp)
fi

echo "==> signing (identity: $SIGNING_IDENTITY; hardened runtime: $HARDENED_RUNTIME; version: $VERSION)"
# Inside-out, no --deep: every nested Mach-O first (deepest first), then each framework
# bundle, then the main executable, then the app, so each seal covers already-signed content.
while IFS= read -r -d '' file; do
  if [[ "$(file -b "$file")" == *Mach-O* ]]; then
    codesign "${SIGN_ARGS[@]}" "$file"
  fi
done < <(find "$APP_BUNDLE/Contents" -depth -type f ! -path "$APP_BUNDLE/Contents/MacOS/*" -print0)
while IFS= read -r -d '' framework; do
  codesign "${SIGN_ARGS[@]}" "$framework"
done < <(find "$APP_BUNDLE/Contents" -depth -type d -name '*.framework' -print0)
# Hardened runtime blocks EventKit (Calendar glance, Reminders) without the calendars
# entitlement. Only the main executable and the app carry it (the app seal re-signs the main
# executable, so both calls need it); the nested adapter binaries get none.
APP_SIGN_ARGS=("${SIGN_ARGS[@]}")
if [[ "$HARDENED_RUNTIME" == 1 ]]; then
  [[ -f "$ENTITLEMENTS" ]] || fail "entitlements file missing: $ENTITLEMENTS"
  APP_SIGN_ARGS+=(--entitlements "$ENTITLEMENTS")
fi
codesign "${APP_SIGN_ARGS[@]}" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
codesign "${APP_SIGN_ARGS[@]}" "$APP_BUNDLE"

echo "==> verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
if [[ "$HARDENED_RUNTIME" == 1 ]]; then
  signed_info="$(codesign -d --verbose=2 "$APP_BUNDLE" 2>&1)"
  [[ "$signed_info" == *flags=*runtime* ]] || fail "hardened runtime flag missing from the signed app"
  signed_entitlements="$(codesign -d --entitlements - --xml "$APP_BUNDLE" 2>/dev/null || true)"
  [[ "$signed_entitlements" == *com.apple.security.personal-information.calendars* ]] \
    || fail "calendars entitlement missing from the hardened app (EventKit would be denied)"
  [[ "$signed_entitlements" == *com.apple.security.device.audio-input* ]] \
    || fail "audio-input entitlement missing from the hardened app (microphone would be denied)"
fi

if [[ "$NOTARIZE" == 1 ]]; then
  archive="$DIST_DIR/$APP_NAME-notarize.zip"
  echo "==> submitting for notarization"
  ditto -c -k --keepParent "$APP_BUNDLE" "$archive"
  if ! result="$(xcrun notarytool submit "$archive" "${NOTARY_AUTH[@]}" --wait --output-format json)"; then
    echo "$result" >&2
    rm -f "$archive"
    fail "notarytool submit failed"
  fi
  rm -f "$archive"
  status="$(plutil -extract status raw -o - - <<<"$result" 2>/dev/null || echo "unknown")"
  submission_id="$(plutil -extract id raw -o - - <<<"$result" 2>/dev/null || echo "unknown")"
  if [[ "$status" != "Accepted" ]]; then
    echo "notarization status: $status (submission $submission_id)" >&2
    if [[ "$submission_id" != "unknown" ]]; then
      xcrun notarytool log "$submission_id" "${NOTARY_AUTH[@]}" >&2 || true
    fi
    fail "notarization was not accepted"
  fi
  xcrun stapler staple "$APP_BUNDLE"
  xcrun stapler validate "$APP_BUNDLE"
  spctl --assess --type execute --verbose=4 "$APP_BUNDLE"
fi

echo "==> done: $APP_BUNDLE"
echo "Drag it to /Applications, or run: open \"$APP_BUNDLE\""
