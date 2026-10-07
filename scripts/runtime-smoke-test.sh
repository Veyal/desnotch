#!/bin/bash
# Launches a packaged app in non-interactive smoke mode, verifies its adapter
# subprocess starts, then SIGTERMs the exact owned app and checks cleanup.
# Waits are bounded polls with a wall-clock deadline (no fixed sleeps), and the
# captured app log lives in a private temp directory that is always removed.
set -euo pipefail

cd "$(dirname "$0")/.."

APP_BUNDLE="${1:-dist/desnotch.app}"
EXECUTABLE="$APP_BUNDLE/Contents/MacOS/desnotch"
ADAPTER_SCRIPT="$APP_BUNDLE/Contents/Resources/MediaRemoteAdapter/mediaremote-adapter.pl"
STARTUP_TIMEOUT="${STARTUP_TIMEOUT:-10}"
SHUTDOWN_TIMEOUT="${SHUTDOWN_TIMEOUT:-10}"

[[ -x "$EXECUTABLE" && -f "$ADAPTER_SCRIPT" ]] || {
  echo "error: packaged app or adapter is missing" >&2
  exit 1
}

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/desnotch-runtime-smoke.XXXXXX")"
SMOKE_LOG="$WORK_DIR/app.log"
APP_PID=""

cleanup() {
  if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2>/dev/null; then
    kill -TERM "$APP_PID" 2>/dev/null || true
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# Print the captured app output (so CI keeps the evidence) and fail.
die() {
  echo "error: $*" >&2
  if [[ -s "$SMOKE_LOG" ]]; then
    echo "--- app output (last 40 lines) ---" >&2
    tail -n 40 "$SMOKE_LOG" >&2
  fi
  exit 1
}

# poll TIMEOUT_SECONDS COMMAND [ARGS...]: re-run COMMAND until it succeeds or the deadline passes.
poll() {
  local timeout="$1"
  shift
  local deadline=$((SECONDS + timeout))
  while ! "$@"; do
    ((SECONDS < deadline)) || return 1
    sleep 0.05
  done
}

# shellcheck disable=SC2317  # invoked indirectly through poll
app_exited() { ! kill -0 "$APP_PID" 2>/dev/null; }

# shellcheck disable=SC2317  # invoked indirectly through poll
find_adapter() {
  kill -0 "$APP_PID" 2>/dev/null || die "packaged app exited during startup"
  adapter_pid="$(pgrep -P "$APP_PID" -f "mediaremote-adapter\.pl" | head -1 || true)"
  [[ -n "$adapter_pid" ]]
}

# shellcheck disable=SC2317  # invoked indirectly through poll
adapter_exited() { ! kill -0 "$adapter_pid" 2>/dev/null; }

DESNOTCH_SMOKE_TEST=1 "$EXECUTABLE" >"$SMOKE_LOG" 2>&1 &
APP_PID=$!

adapter_pid=""
poll "$STARTUP_TIMEOUT" find_adapter || die "MediaRemote adapter did not start within ${STARTUP_TIMEOUT}s"

kill -TERM "$APP_PID"
poll "$SHUTDOWN_TIMEOUT" app_exited || die "packaged app did not terminate within ${SHUTDOWN_TIMEOUT}s of SIGTERM"
wait "$APP_PID" || true

# The app reaps its adapter on SIGTERM; allow a short bounded grace for the child to be reaped.
poll 3 adapter_exited || die "adapter process $adapter_pid survived app termination"

echo "runtime smoke passed: startup, adapter launch, SIGTERM cleanup ($APP_BUNDLE)"
