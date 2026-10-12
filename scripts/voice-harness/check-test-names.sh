#!/bin/bash
# Fails when a test method or class that a work package document MANDATES is missing from Tests/.
# Companion of check-rule-tests.sh (which covers WP-LOGIC); this one covers the other packages.
#
# usage: scripts/voice-harness/check-test-names.sh <WP-UI|WP-PLATFORM|WP-HERMES-A|WP-HERMES-B> [--names]
#   --names   only print the mandated method names (what the script extracts from the document)
#
# How it works: every `testXxx` token written in backticks in the package document (for WP-HERMES, only in the
# section of the part: A.9 for part A, B.6 + B.9 for part B) is a mandated test method name, and every class
# listed below must be declared as an XCTestCase. A method counts as present when `func <name>(` appears
# anywhere under Tests/ (the existing tests that a package must update are found the same way).
# A few classes also have a minimum number of test methods (the "at least N" counts of the documents).
# The test directory can be overridden for the script's own self-test: TEST_DIR=<dir> scripts/voice-harness/check-test-names.sh ...
set -euo pipefail

repo="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo"

wp="${1:-}"
mode="${2:-}"
dir="${TEST_DIR:-Tests}"

doc_section() {   # doc, start-regex, end-regex -> the lines from start to end (exclusive of the end line)
  awk -v s="$2" -v e="$3" '$0 ~ s { on = 1; next } on && $0 ~ e { on = 0 } on { print }' "$1"
}

case "$wp" in
  WP-UI)
    text="$(cat docs/voice/WP-UI.md)"
    classes="VoiceSectionPresentationTests VoiceSectionRenderTests VoiceWingSelectionTests VoiceHoverPolicyTests VoiceStatusMenuTextTests VoiceCuePlayerTests VoiceAccessibilityTextTests"
    ;;
  WP-PLATFORM)
    text="$(cat docs/voice/WP-PLATFORM.md)"
    classes="LevelMeterTests VoiceHotkeyMapTests PressTrackerTests CarbonHotKeyOutcomeTests CarbonPushToTalkLifecycleTests LockFlagsTests ScreenLockMonitorTests SystemLocalExecutorTests MuteMemoryTests VolumeDuckerTests AuditChainTests FileAuditLoggerTests DiskFileWriterTests SystemVoicePermissionsTests SpeechDecisionTests"
    ;;
  WP-HERMES-A)
    text="$(doc_section docs/voice/WP-HERMES.md '^### A\.9' '^\*\*Part A gate')"
    classes="VoiceCoordinatorLocalTests DailyTurnCounterTests VoiceTimersTests"
    ;;
  WP-HERMES-B)
    text="$({ doc_section docs/voice/WP-HERMES.md '^### B\.6' '^### B\.7'; doc_section docs/voice/WP-HERMES.md '^### B\.9' '^\*\*Part B gate'; })"
    classes="VoiceCoordinatorHermesTests MiniConfigScanTests HermesPreflightTests ACPClientTests HermesEventMapperTests HermesProcessGuardTests HermesAgentBackendTests"
    ;;
  *)
    echo "usage: check-test-names.sh <WP-UI|WP-PLATFORM|WP-HERMES-A|WP-HERMES-B> [--names]" >&2
    exit 64
    ;;
esac

names="$(printf '%s\n' "$text" | grep -oE '`test[A-Za-z0-9_]+`' | tr -d '`' | grep -vE '_$' | sort -u || true)"
if [[ "$mode" == "--names" ]]; then
  printf '%s\n' "$names"
  exit 0
fi

missing=0
count=0

for n in $names; do
  count=$((count + 1))
  if ! grep -rqE "func $n\(" "$dir" 2>/dev/null; then
    echo "no test method $n (mandated by the $wp document)"
    missing=$((missing + 1))
  fi
done

for c in $classes; do
  count=$((count + 1))
  if ! grep -rqE "class $c: XCTestCase" "$dir" 2>/dev/null; then
    echo "no XCTestCase class $c (mandated by the $wp document)"
    missing=$((missing + 1))
  fi
done

# need_at_least <file-name> <class> <minimum>: number of test methods in the file
need_at_least() {
  local file="$1" min="$2" found total
  found="$(grep -rl --include="$file" -E 'func test' "$dir" 2>/dev/null | head -1 || true)"
  count=$((count + 1))
  if [[ -z "$found" ]]; then
    echo "no file $file (needs at least $min test methods)"
    missing=$((missing + 1))
    return
  fi
  total="$(grep -cE 'func test' "$found" || true)"
  if (( total < min )); then
    echo "$file has $total test methods, the $wp document requires at least $min"
    missing=$((missing + 1))
  fi
}

case "$wp" in
  WP-PLATFORM)
    need_at_least LockFlagsTests.swift 14
    ;;
  WP-UI)
    need_at_least VoiceSectionPresentationTests.swift 30
    ;;
esac

if [[ "$missing" == 0 ]]; then
  echo "check-test-names: $wp: all $count mandated test methods, classes and counts exist"
  exit 0
fi
echo "check-test-names: $wp: $missing of $count mandated items are missing" >&2
exit 1
