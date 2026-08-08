#!/bin/bash
# Build release .app. Ad-hoc codesign only; no notarization.
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="desnotch"
DIST_DIR="dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null || echo "0.1.0")}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo "1")}"

VERSION="${VERSION#v}"
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]] || { echo "error: VERSION must be dotted numeric (got '$VERSION')" >&2; exit 1; }
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || { echo "error: BUILD_NUMBER must be positive integer (got '$BUILD_NUMBER')" >&2; exit 1; }

echo "==> swift build -c release"
swift build -c release

BIN_PATH=".build/release/$APP_NAME"
SPM_RESOURCE_BUNDLE=".build/release/${APP_NAME}_DesnotchCore.bundle"
ADAPTER_SRC="$SPM_RESOURCE_BUNDLE/MediaRemoteAdapter"
[ -x "$BIN_PATH" ] || { echo "error: release binary not found at $BIN_PATH" >&2; exit 1; }
[ -d "$ADAPTER_SRC" ] || { echo "error: adapter resources not found at $ADAPTER_SRC" >&2; exit 1; }
[ -f "$ADAPTER_SRC/mediaremote-adapter.pl" ] || { echo "error: adapter script missing" >&2; exit 1; }
[ -d "$ADAPTER_SRC/MediaRemoteAdapter.framework" ] || { echo "error: adapter framework missing" >&2; exit 1; }

echo "==> assembling $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp -R "$ADAPTER_SRC" "$APP_BUNDLE/Contents/Resources/MediaRemoteAdapter"

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>desnotch</string>
    <key>CFBundleIdentifier</key><string>com.desnotch.app</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSCalendarsUsageDescription</key><string>desnotch shows your next meeting in the notch pill.</string>
    <key>NSCalendarsFullAccessUsageDescription</key><string>desnotch shows your next meeting in the notch pill.</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_BUNDLE/Contents/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_BUNDLE/Contents/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$APP_BUNDLE/Contents/Info.plist" >/dev/null

codesign --force --sign - "$APP_BUNDLE/Contents/Resources/MediaRemoteAdapter/MediaRemoteAdapter.framework"
codesign --force --sign - "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
codesign --force --sign - "$APP_BUNDLE"

echo "==> done: $APP_BUNDLE"
echo "Drag it to /Applications, or run: open \"$APP_BUNDLE\""
