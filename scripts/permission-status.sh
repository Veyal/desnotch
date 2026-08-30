#!/bin/bash
# Reports the packaged app's own permission state without requesting access.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_BUNDLE="${1:-dist/desnotch.app}"
EXECUTABLE="$APP_BUNDLE/Contents/MacOS/desnotch"
REQUIRE_GRANTED="${REQUIRE_GRANTED:-0}"
REQUIRE_REMINDERS_GRANTED="${REQUIRE_REMINDERS_GRANTED:-0}"
[[ "$REQUIRE_GRANTED" == 0 || "$REQUIRE_GRANTED" == 1 ]] || {
  echo "error: REQUIRE_GRANTED must be 0 or 1" >&2
  exit 1
}
[[ "$REQUIRE_REMINDERS_GRANTED" == 0 || "$REQUIRE_REMINDERS_GRANTED" == 1 ]] || {
  echo "error: REQUIRE_REMINDERS_GRANTED must be 0 or 1" >&2
  exit 1
}
[[ -x "$EXECUTABLE" ]] || {
  echo "error: packaged app executable is missing: $EXECUTABLE" >&2
  exit 1
}

# Caveat: the probe runs as a child of this shell, so TCC may attribute the
# Accessibility check to the responsible process (Terminal, the CI runner)
# rather than com.desnotch.app. "trusted" here can therefore be a false
# positive for the .app when launched normally (e.g. via `open`/Finder);
# verify the launched app itself before relying on REQUIRE_GRANTED=1.
snapshot="$(DESNOTCH_PERMISSION_PROBE=1 "$EXECUTABLE")"
accessibility="$(plutil -extract accessibility raw -o - - <<<"$snapshot")"
calendar="$(plutil -extract calendar raw -o - - <<<"$snapshot")"
reminders="$(plutil -extract reminders raw -o - - <<<"$snapshot")"

echo "$snapshot"

if [[ "$REQUIRE_GRANTED" == 1 ]]; then
  [[ "$accessibility" == trusted ]] || {
    echo "error: Accessibility is $accessibility" >&2
    exit 2
  }
  [[ "$calendar" == fullAccess ]] || {
    echo "error: Calendar is $calendar" >&2
    exit 2
  }
fi

if [[ "$REQUIRE_REMINDERS_GRANTED" == 1 && "$reminders" != fullAccess ]]; then
  echo "error: Reminders is $reminders" >&2
  exit 2
fi
