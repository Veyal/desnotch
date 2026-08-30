#!/bin/bash
# Static checks for a packaged app. Does not launch the app or request permissions.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_BUNDLE="${1:-dist/desnotch.app}"
APP_NAME="desnotch"
PLIST="$APP_BUNDLE/Contents/Info.plist"
EXECUTABLE="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
ADAPTER="$APP_BUNDLE/Contents/Resources/MediaRemoteAdapter"

[[ -d "$APP_BUNDLE" ]] || { echo "error: app bundle not found: $APP_BUNDLE" >&2; exit 1; }
[[ -f "$PLIST" && -x "$EXECUTABLE" ]] || { echo "error: missing plist or executable" >&2; exit 1; }
[[ -f "$APP_BUNDLE/Contents/Resources/AppIcon.icns" ]] || { echo "error: AppIcon.icns missing" >&2; exit 1; }
[[ -f "$ADAPTER/mediaremote-adapter.pl" && -d "$ADAPTER/MediaRemoteAdapter.framework" ]] || { echo "error: MediaRemote adapter resources missing" >&2; exit 1; }

/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$PLIST" >/dev/null
/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$PLIST" >/dev/null
/usr/libexec/PlistBuddy -c "Print :CFBundleIconFile" "$PLIST" >/dev/null
/usr/libexec/PlistBuddy -c "Print :NSCalendarsUsageDescription" "$PLIST" >/dev/null
/usr/libexec/PlistBuddy -c "Print :NSRemindersUsageDescription" "$PLIST" >/dev/null
/usr/libexec/PlistBuddy -c "Print :NSRemindersFullAccessUsageDescription" "$PLIST" >/dev/null
plutil -lint "$PLIST"

archs="$(lipo -archs "$EXECUTABLE")"
expected_arch="${EXPECTED_ARCH:-$(uname -m)}"
[[ " $archs " == *" $expected_arch "* ]] || { echo "error: executable architectures are '$archs'; expected $expected_arch" >&2; exit 1; }
if [[ "${REQUIRE_UNIVERSAL:-0}" == 1 ]]; then
  [[ "$archs" == *arm64* && "$archs" == *x86_64* ]] || { echo "error: REQUIRE_UNIVERSAL=1 but architectures are '$archs'" >&2; exit 1; }
fi
codesign --verify --strict --verbose=2 "$ADAPTER/MediaRemoteAdapter.framework"
codesign --verify --strict --verbose=2 "$APP_BUNDLE"

# A previously crashed app must not leave the adapter owned by launchd. Only
# adapters launched from this bundle count: unrelated tools (nowplaying-cli,
# media-control) run the same script from their own paths.
BUNDLE_ABS="$(cd "$APP_BUNDLE" && pwd)"
if ps -axo pid=,ppid=,command= | awk -v bundle="$BUNDLE_ABS" '$2 == 1 && index($0, bundle) && $0 ~ /mediaremote-adapter\.pl/ {found=1} END {exit found ? 0 : 1}'; then
  echo "error: orphaned mediaremote-adapter process detected" >&2
  exit 1
fi

echo "smoke checks passed: $APP_BUNDLE ($archs)"

if [[ "${MANUAL:-0}" == 1 ]]; then
  cat <<'CHECKLIST'
Manual checklist (requires a packaged app and a real desktop session):
  [ ] Launch and confirm the status-menu Quit path terminates desnotch and its adapter.
  [ ] Run REQUIRE_GRANTED=1 scripts/permission-status.sh and confirm all required grants.
  [ ] Grant Calendar, Reminders, and Accessibility when enabled; verify denied/retry guidance.
  [ ] Play/pause media and verify the pill updates; test volume scroll and menu transport.
  [ ] Exercise notification mirroring only after enabling it and granting Accessibility.
  [ ] On a real notched MacBook, verify the pill never draws behind the cutout.
  [ ] On Intel hardware, verify launch, media adapter operation, and clean termination.
CHECKLIST
fi
