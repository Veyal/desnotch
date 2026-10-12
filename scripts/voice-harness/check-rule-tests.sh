#!/bin/bash
# Fails when a mandated WP-LOGIC test method is missing from Tests/DesnotchCoreTests/Voice/Logic/. Run it after WP-LOGIC.
#
# Checked, by method NAME (one method per row, so a loop over a table does not count as many cases):
#   - every reducer rule ID listed in docs/voice/PLAN.md section 7:   func testR<ID>_...      (VoiceReducerRuleTests.swift)
#   - the ten reducer scenarios:                                       func testScenarioS<1..10>_...
#   - the worked-example tables of docs/voice/WP-LOGIC.md:
#       normalizer N1..N14, spoken number S1..S34, router 1..72 (testRouter_<n>_), tool tiers T1..T32,
#       command scanner C1..C33 (C26b is folded into testC26_), rate limiter L1..L11
#
# usage: scripts/voice-harness/check-rule-tests.sh [--ids]    (--ids only prints the reducer rule IDs)
# The directory can be overridden for the script's own self-test: LOGIC_TEST_DIR=<dir> scripts/voice-harness/check-rule-tests.sh
set -euo pipefail

repo="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo"

# Table rows ("| R31 |") plus the two IDs that only appear inline in the HANDLE_FINAL steps ("(rule R50)", "(R51)").
ids="$({ grep -oE '^\| R[0-9]+[a-z]? \|' docs/voice/PLAN.md | tr -d '| '; grep -oE '\((rule )?R[0-9]+[a-z]?\)' docs/voice/PLAN.md | grep -oE 'R[0-9]+[a-z]?'; } | sort -u)"
if [[ "${1:-}" == "--ids" ]]; then
  echo "$ids"
  exit 0
fi

dir="${LOGIC_TEST_DIR:-Tests/DesnotchCoreTests/Voice/Logic}"
missing=0
count=0

# need <label> <file> <pattern-with-%s> <first> <last>
need_range() {
  local label="$1" file="$2" pattern="$3" first="$4" last="$5" n
  for ((n = first; n <= last; n++)); do
    count=$((count + 1))
    # shellcheck disable=SC2059
    if ! grep -qE "func $(printf "$pattern" "$n")" "$dir/$file" 2>/dev/null; then
      echo "no test for $label $n in $file (expected: func $(printf "$pattern" "$n")...)"
      missing=$((missing + 1))
    fi
  done
}

for id in $ids; do
  count=$((count + 1))
  if ! grep -rqE "func test${id}_" "$dir" 2>/dev/null; then
    echo "no test for rule $id (expected: func test${id}_...)"
    missing=$((missing + 1))
  fi
done

need_range "scenario S" VoiceReducerScenarioTests.swift 'testScenarioS%d_' 1 10
need_range "normalizer N" UtteranceNormalizerTests.swift 'testN%d_' 1 14
need_range "spoken number S" SpokenNumberTests.swift 'testS%d_' 1 34
need_range "router row" IntentRouterTests.swift 'testRouter_%d_' 1 72
need_range "tool tier T" ToolTierTableTests.swift 'testT%d_' 1 32
need_range "scanner C" CommandRiskScannerTests.swift 'testC%d_' 1 33
need_range "rate limiter L" RateLimiterTests.swift 'testL%d_' 1 11

# Extra named router tests of the open-app grammar (WP-LOGIC "Open-app grammar"), beyond the 72 rows.
for name in testRouterOpenUpSafariUsesTheLongestVerb testRouterBukaAplikasiAloneIsUnknownApp; do
  count=$((count + 1))
  if ! grep -qE "func ${name}\(" "$dir/IntentRouterTests.swift" 2>/dev/null; then
    echo "no test $name in IntentRouterTests.swift"
    missing=$((missing + 1))
  fi
done

# Minimum number of test methods in the catalog tests (WP-LOGIC: 18 rows plus the negative and invariant tests).
count=$((count + 1))
catalog_methods="$(grep -cE 'func test' "$dir/AppCatalogTests.swift" 2>/dev/null || true)"
if [[ "${catalog_methods:-0}" -lt 22 ]]; then
  echo "AppCatalogTests.swift has ${catalog_methods:-0} test methods, WP-LOGIC requires at least 22"
  missing=$((missing + 1))
fi

if [[ "$missing" == 0 ]]; then
  echo "check-rule-tests: all $count mandated test methods exist"
  exit 0
fi
echo "check-rule-tests: $missing of $count mandated test methods are missing" >&2
exit 1
