#!/bin/bash
# Reports the packaged app's own permission state without requesting access.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_BUNDLE="${1:-dist/desnotch.app}"
EXECUTABLE="$APP_BUNDLE/Contents/MacOS/desnotch"
REQUIRE_GRANTED="${REQUIRE_GRANTED:-0}"
[[ "$REQUIRE_GRANTED" == 0 || "$REQUIRE_GRANTED" == 1 ]] || {
  echo "error: REQUIRE_GRANTED must be 0 or 1" >&2
  exit 1
}
[[ -x "$EXECUTABLE" ]] || {
  echo "error: packaged app executable is missing: $EXECUTABLE" >&2
  exit 1
}

snapshot="$(DESNOTCH_PERMISSION_PROBE=1 "$EXECUTABLE")"
accessibility="$(plutil -extract accessibility raw -o - - <<<"$snapshot")"
microphone="$(plutil -extract microphone raw -o - - <<<"$snapshot")"
calendar="$(plutil -extract calendar raw -o - - <<<"$snapshot")"

echo "$snapshot"

if [[ "$REQUIRE_GRANTED" == 1 ]]; then
  [[ "$accessibility" == trusted ]] || {
    echo "error: Accessibility is $accessibility" >&2
    exit 2
  }
  [[ "$microphone" == authorized ]] || {
    echo "error: Microphone is $microphone" >&2
    exit 2
  }
  [[ "$calendar" == fullAccess ]] || {
    echo "error: Calendar is $calendar" >&2
    exit 2
  }
fi
