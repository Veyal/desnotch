#!/bin/bash
# Fails when a reducer rule ID listed in docs/voice/PLAN.md section 7 has no test method named
# testR<ID>_... in Tests/DesnotchCoreTests/Voice/Logic/. Run it after WP-LOGIC.
#
# usage: scripts/voice-harness/check-rule-tests.sh [--ids]    (--ids only prints the rule IDs)
set -euo pipefail

repo="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo"

# Table rows ("| R31 |") plus the two IDs that only appear inline in the HANDLE_FINAL steps ("(rule R50)", "(R51)").
ids="$({ grep -oE '^\| R[0-9]+[a-z]? \|' docs/voice/PLAN.md | tr -d '| '; grep -oE '\((rule )?R[0-9]+[a-z]?\)' docs/voice/PLAN.md | grep -oE 'R[0-9]+[a-z]?'; } | sort -u)"
if [[ "${1:-}" == "--ids" ]]; then
  echo "$ids"
  exit 0
fi

dir="Tests/DesnotchCoreTests/Voice/Logic"
missing=0
count=0
for id in $ids; do
  count=$((count + 1))
  if ! grep -rqE "func test${id}_" "$dir" 2>/dev/null; then
    echo "no test for rule $id (expected: func test${id}_...)"
    missing=$((missing + 1))
  fi
done
if [[ "$missing" == 0 ]]; then
  echo "check-rule-tests: all $count rule IDs have a test"
  exit 0
fi
echo "check-rule-tests: $missing of $count rule IDs have no test" >&2
exit 1
