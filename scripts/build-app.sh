#!/bin/bash
# Build the distributable .app. Host-native, ad-hoc signing is the default.
# Optional distribution knobs are intentionally environment/config driven:
#   UNIVERSAL=1 SIGNING_IDENTITY="Developer ID Application: ..." HARDENED_RUNTIME=1
#   NOTARIZE=1 NOTARY_PROFILE="notarytool-keychain-profile"
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="desnotch"
DIST_DIR="${DIST_DIR:-dist}"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null || echo "0.1.0")}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo "1")}"
BUNDLE_ID="${BUNDLE_ID:-com.desnotch.app}"
UNIVERSAL="${UNIVERSAL:-0}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
HARDENED_RUNTIME="${HARDENED_RUNTIME:-0}"
NOTARIZE="${NOTARIZE:-0}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

VERSION="${VERSION#v}"
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]] || { echo "error: VERSION must be dotted numeric (got '$VERSION')" >&2; exit 1; }
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || { echo "error: BUILD_NUMBER must be positive integer (got '$BUILD_NUMBER')" >&2; exit 1; }
[[ "$BUNDLE_ID" =~ ^[A-Za-z0-9.-]+$ && "$BUNDLE_ID" == *.* ]] || { echo "error: BUNDLE_ID must be a stable reverse-DNS identifier (got '$BUNDLE_ID')" >&2; exit 1; }
[[ "$UNIVERSAL" == 0 || "$UNIVERSAL" == 1 ]] || { echo "error: UNIVERSAL must be 0 or 1" >&2; exit 1; }
[[ "$HARDENED_RUNTIME" == 0 || "$HARDENED_RUNTIME" == 1 ]] || { echo "error: HARDENED_RUNTIME must be 0 or 1" >&2; exit 1; }
[[ "$NOTARIZE" == 0 || "$NOTARIZE" == 1 ]] || { echo "error: NOTARIZE must be 0 or 1" >&2; exit 1; }
if [[ "$NOTARIZE" == 1 && -z "$NOTARY_PROFILE" ]]; then
  echo "error: NOTARIZE=1 requires NOTARY_PROFILE (a notarytool keychain profile)" >&2
  exit 1
fi
if [[ "$NOTARIZE" == 1 && ( "$SIGNING_IDENTITY" == "-" || "$HARDENED_RUNTIME" != 1 ) ]]; then
  echo "error: NOTARIZE=1 requires Developer ID signing and HARDENED_RUNTIME=1" >&2
  exit 1
fi

build_host() {
  echo "==> swift build -c release" >&2
  swift build -c release >&2 || return
  echo ".build/release/$APP_NAME"
}

build_universal() {
  local arch triple scratch binary
  local -a binaries
  for arch in arm64 x86_64; do
    triple="$arch-apple-macosx13.0"
    scratch=".build-release-$arch"
    echo "==> swift build -c release --triple $triple" >&2
    swift build -c release --triple "$triple" --scratch-path "$scratch" >&2 || return
    binary="$(find "$scratch" -type f -path '*/release/'"$APP_NAME" -perm -111 -print -quit)"
    [[ -n "$binary" ]] || { echo "error: $arch release binary not found" >&2; exit 1; }
    binaries+=("$binary")
  done
  mkdir -p .build-universal
  lipo -create "${binaries[0]}" "${binaries[1]}" -output .build-universal/$APP_NAME
  chmod 755 .build-universal/$APP_NAME
  echo ".build-universal/$APP_NAME"
}

if [[ "$UNIVERSAL" == 1 ]]; then
  BIN_PATH="$(build_universal)"
  RESOURCE_BUNDLE="$(find .build-release-arm64 -type d -name "${APP_NAME}_DesnotchCore.bundle" -print -quit)"
else
  BIN_PATH="$(build_host)"
  RESOURCE_BUNDLE=".build/release/${APP_NAME}_DesnotchCore.bundle"
fi

ADAPTER_SRC="$RESOURCE_BUNDLE/MediaRemoteAdapter"
[[ -x "$BIN_PATH" ]] || { echo "error: release binary not found at $BIN_PATH" >&2; exit 1; }
[[ -d "$ADAPTER_SRC" ]] || { echo "error: adapter resources not found at $ADAPTER_SRC" >&2; exit 1; }
[[ -f "$ADAPTER_SRC/mediaremote-adapter.pl" ]] || { echo "error: adapter script missing" >&2; exit 1; }
[[ -d "$ADAPTER_SRC/MediaRemoteAdapter.framework" ]] || { echo "error: adapter framework missing" >&2; exit 1; }

echo "==> assembling $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp -R "$ADAPTER_SRC" "$APP_BUNDLE/Contents/Resources/MediaRemoteAdapter"
cp Assets/AppIcon.icns "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

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
    <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP_BUNDLE/Contents/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Print :CFBundleIconFile" "$APP_BUNDLE/Contents/Info.plist" >/dev/null

SIGN_ARGS=(--force --sign "$SIGNING_IDENTITY")
[[ "$HARDENED_RUNTIME" == 1 ]] && SIGN_ARGS+=(--options runtime)
echo "==> signing (identity: $SIGNING_IDENTITY; hardened runtime: $HARDENED_RUNTIME)"
codesign "${SIGN_ARGS[@]}" "$APP_BUNDLE/Contents/Resources/MediaRemoteAdapter/MediaRemoteAdapter.framework"
codesign "${SIGN_ARGS[@]}" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
codesign "${SIGN_ARGS[@]}" "$APP_BUNDLE"

if [[ "$NOTARIZE" == 1 ]]; then
  archive="$DIST_DIR/$APP_NAME-notarize.zip"
  echo "==> submitting for notarization via keychain profile $NOTARY_PROFILE"
  ditto -c -k --keepParent "$APP_BUNDLE" "$archive"
  xcrun notarytool submit "$archive" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP_BUNDLE"
  rm -f "$archive"
fi

echo "==> done: $APP_BUNDLE"
echo "Drag it to /Applications, or run: open \"$APP_BUNDLE\""
