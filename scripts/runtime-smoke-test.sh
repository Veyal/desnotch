#!/bin/bash
# Launches a packaged app in non-interactive smoke mode, verifies its adapter
# subprocess starts, then SIGTERMs the exact owned app and checks cleanup.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_BUNDLE="${1:-dist/desnotch.app}"
EXECUTABLE="$APP_BUNDLE/Contents/MacOS/desnotch"
ADAPTER_SCRIPT="$APP_BUNDLE/Contents/Resources/MediaRemoteAdapter/mediaremote-adapter.pl"
[[ -x "$EXECUTABLE" && -f "$ADAPTER_SCRIPT" ]] || {
  echo "error: packaged app or adapter is missing" >&2
  exit 1
}

SMOKE_LOG="$(mktemp -t desnotch-runtime-smoke).log"
DESNOTCH_SMOKE_TEST=1 "$EXECUTABLE" >"$SMOKE_LOG" 2>&1 &
APP_PID=$!

cleanup() {
  if kill -0 "$APP_PID" 2>/dev/null; then
    kill -TERM "$APP_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

adapter_pid=""
for _ in {1..50}; do
  kill -0 "$APP_PID" 2>/dev/null || {
    echo "error: packaged app exited during startup; log: $SMOKE_LOG" >&2
    exit 1
  }
  adapter_pid="$(pgrep -P "$APP_PID" -f "mediaremote-adapter\.pl" | head -1 || true)"
  [[ -n "$adapter_pid" ]] && break
  sleep 0.1
done
[[ -n "$adapter_pid" ]] || {
  echo "error: MediaRemote adapter did not start; log: $SMOKE_LOG" >&2
  exit 1
}

kill -TERM "$APP_PID"
for _ in {1..50}; do
  kill -0 "$APP_PID" 2>/dev/null || break
  sleep 0.1
done
if kill -0 "$APP_PID" 2>/dev/null; then
  echo "error: packaged app did not terminate after SIGTERM; log: $SMOKE_LOG" >&2
  exit 1
fi
wait "$APP_PID" || true

if kill -0 "$adapter_pid" 2>/dev/null; then
  echo "error: adapter process $adapter_pid survived app termination" >&2
  exit 1
fi

trap - EXIT
echo "runtime smoke passed: startup, adapter launch, SIGTERM cleanup ($APP_BUNDLE)"
