#!/bin/bash
# Builds and runs the desnotch tests without Apple's XCTest (Command Line Tools machines).
#
# It mirrors Sources/DesnotchCore and Tests/DesnotchCoreTests into a scratch SwiftPM package
# next to a minimal stub `XCTest` module, generates a runner that calls every `testXxx`
# method, builds it, and runs it. CI still runs the real `swift test`; this is the local
# stand-in. Nothing here touches the repository's own .build directory.
#
# usage: scripts/voice-harness/run.sh [options]
#   --filter TEXT   run only tests whose "Class.testName" contains TEXT
#   --skip-build    reuse the previous build (re-run only)
#   --list          print the generated test list and exit
#   env HARNESS_DIR overrides the scratch package location (default: <repo>/.build/voice-harness)
#   env HARNESS_SKIP_FILE overrides the list of test files left out (default: skip.txt next to this script)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
work="${HARNESS_DIR:-$repo/.build/voice-harness}"
skip_file="${HARNESS_SKIP_FILE:-$here/skip.txt}"
filter=""
skip_build=0
list_only=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --filter) filter="${2:?--filter needs a value}"; shift 2 ;;
    --skip-build) skip_build=1; shift ;;
    --list) list_only=1; shift ;;
    *) echo "unknown option: $1" >&2; exit 64 ;;
  esac
done

mkdir -p "$work/Sources/XCTest" "$work/Sources/runner/Tests"

if [[ "$skip_build" == 0 ]]; then
  rsync -a --delete --exclude '.DS_Store' "$repo/Sources/DesnotchCore/" "$work/Sources/DesnotchCore/"
  cp "$here/stub-xctest/XCTest.swift" "$work/Sources/XCTest/XCTest.swift"
  rsync -a --delete --exclude '.DS_Store' "$repo/Tests/DesnotchCoreTests/" "$work/Sources/runner/Tests/"
  if [[ -f "$skip_file" ]]; then
    while IFS= read -r name; do
      [[ -z "$name" || "$name" == \#* ]] && continue
      rm -f "$work/Sources/runner/Tests/$name"
    done <"$skip_file"
  fi
  cat >"$work/Package.swift" <<'PACKAGE'
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "harness",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "XCTest", path: "Sources/XCTest"),
        .target(
            name: "DesnotchCore",
            path: "Sources/DesnotchCore",
            resources: [.copy("MediaRemote/Vendor/MediaRemoteAdapter")]
        ),
        .executableTarget(
            name: "runner",
            dependencies: ["DesnotchCore", "XCTest"],
            path: "Sources/runner"
        )
    ]
)
PACKAGE
  python3 "$here/gen_runner.py" "$work/Sources/runner/Tests" >"$work/Sources/runner/main.swift"
fi

if [[ "$list_only" == 1 ]]; then
  grep -oE 'run(Sync|Async)\([A-Za-z0-9_]+\.self, "[A-Za-z0-9_]+"' "$work/Sources/runner/main.swift" \
    | sed -E 's/^run(Sync|Async)\(//; s/\.self, "/./; s/"$//'
  exit 0
fi

if [[ "$skip_build" == 0 ]]; then
  (cd "$work" && swift build --product runner 2>&1)
fi

cd "$work"
log="$work/last-run.log"
status=0
TEST_FILTER="$filter" "$work/.build/debug/runner" 2>&1 | tee "$log" || status=$?

# Failures listed in known-failures.txt are baseline limitations of the stub, not regressions.
failed_line="$(grep '^failed: ' "$log" | tail -1 | sed 's/^failed: //' || true)"
unexpected=()
if [[ -n "$failed_line" ]]; then
  IFS=',' read -r -a failed_names <<<"$failed_line"
  for name in "${failed_names[@]}"; do
    name="${name// /}"
    if ! grep -qxF "$name" "$here/known-failures.txt"; then
      unexpected+=("$name")
    fi
  done
fi
if [[ ${#unexpected[@]} -gt 0 ]]; then
  echo "harness: UNEXPECTED failures: ${unexpected[*]}" >&2
  exit 1
fi
if [[ "$status" != 0 && -n "$failed_line" ]]; then
  echo "harness: only known baseline failures remain (see known-failures.txt)"
  exit 0
fi
exit "$status"
