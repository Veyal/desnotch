#!/bin/bash
# Builds desnotch in release mode and bundles it into a minimal double-clickable
# desnotch.app under ./dist. Ad-hoc codesigned only - no notarization for this MVP.
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="desnotch"
DIST_DIR="dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"

echo "==> swift build -c release"
swift build -c release

BIN_PATH=".build/release/$APP_NAME"
RESOURCE_BUNDLE=".build/release/${APP_NAME}_${APP_NAME}.bundle"

echo "==> assembling $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# SPM's generated Bundle.module accessor looks for this next to Bundle.main
# (the .app root), not under Contents/Resources - it must sit here, not nested.
if [ -d "$RESOURCE_BUNDLE" ]; then
    cp -R "$RESOURCE_BUNDLE" "$APP_BUNDLE/$(basename "$RESOURCE_BUNDLE")"
else
    echo "error: resource bundle not found at $RESOURCE_BUNDLE (MediaRemote adapter would be missing from the .app)" >&2
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
    <string>0.1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo "==> ad-hoc codesigning"
codesign --force --deep --sign - "$APP_BUNDLE"

echo "==> done: $APP_BUNDLE"
echo "Drag it to /Applications, or run: open \"$APP_BUNDLE\""
