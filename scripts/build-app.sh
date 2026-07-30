#!/bin/bash
# Builds desnotch in release mode and bundles it into a minimal double-clickable
# desnotch.app under ./dist. Ad-hoc codesigned only - no notarization for this MVP.
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="desnotch"
DIST_DIR="dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"

# Version: prefer an explicit env override, then the latest git tag, then a default.
VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null || echo "0.1.0")}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo "1")}"

echo "==> swift build -c release"
swift build -c release

BIN_PATH=".build/release/$APP_NAME"
# After the DesnotchCore library split, the SPM resource bundle is named after the
# target that owns the resources (DesnotchCore), not the executable.
SPM_RESOURCE_BUNDLE=".build/release/${APP_NAME}_DesnotchCore.bundle"
ADAPTER_SRC="$SPM_RESOURCE_BUNDLE/MediaRemoteAdapter"

echo "==> assembling $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# The MediaRemote adapter ships under Contents/Resources (sealed by codesign, so the
# bundle is notarizable) and is resolved via Bundle.main.resourceURL at runtime; the
# SPM resource bundle (Bundle.module) remains the fallback for `swift run`.
if [ -d "$ADAPTER_SRC" ]; then
    cp -R "$ADAPTER_SRC" "$APP_BUNDLE/Contents/Resources/MediaRemoteAdapter"
else
    echo "error: adapter not found at $ADAPTER_SRC (MediaRemote adapter would be missing from the .app)" >&2
    exit 1
fi

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>desnotch</string>
    <key>CFBundleIdentifier</key>
    <string>com.desnotch.app</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSCalendarsUsageDescription</key>
    <string>desnotch shows your next meeting in the notch pill.</string>
    <key>NSCalendarsFullAccessUsageDescription</key>
    <string>desnotch shows your next meeting in the notch pill.</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo "==> ad-hoc codesigning (inside-out)"
# Sign the embedded adapter framework first, then the binary, then the bundle - avoid
# --deep (deprecated) so each component has its own signature as notarization requires.
# --options runtime / --timestamp are intentionally omitted: they need a Developer ID
# certificate, not an ad-hoc ("-") identity.
codesign --force --sign - "$APP_BUNDLE/Contents/Resources/MediaRemoteAdapter/MediaRemoteAdapter.framework"
codesign --force --sign - "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
codesign --force --sign - "$APP_BUNDLE"

echo "==> done: $APP_BUNDLE"
echo "Drag it to /Applications, or run: open \"$APP_BUNDLE\""
