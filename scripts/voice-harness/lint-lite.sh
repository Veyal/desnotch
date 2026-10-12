#!/bin/bash
# Local stand-in for the SwiftLint rules CI enforces (.swiftlint.yml): trailing_whitespace,
# trailing_newline, vertical_whitespace (no two blank lines in a row), leading_whitespace
# (a file must not start with a blank line). Checks the given files, or every .swift file that
# differs from the base commit when none are given. Exit 1 when anything is found.
set -euo pipefail

repo="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo"

files=()
if [[ $# -gt 0 ]]; then
  files=("$@")
fi
if [[ ${#files[@]} -eq 0 ]]; then
  while IFS= read -r f; do
    [[ "$f" == *.swift ]] && files+=("$f")
  done < <({ git diff --name-only HEAD; git ls-files --others --exclude-standard; } | sort -u)
fi

status=0
for f in ${files[@]+"${files[@]}"}; do
  [[ -f "$f" ]] || continue
  if grep -nE '[[:space:]]+$' "$f" >/dev/null; then
    echo "trailing whitespace: $f"
    grep -nE '[[:space:]]+$' "$f" | head -3
    status=1
  fi
  if [[ -s "$f" && "$(tail -c1 "$f" | xxd -p)" != "0a" ]]; then
    echo "missing final newline: $f"
    status=1
  fi
  if [[ -s "$f" && -z "$(head -1 "$f" | tr -d '[:space:]')" ]]; then
    echo "starts with a blank line: $f"
    status=1
  fi
  if awk 'prev == "" && $0 == "" && NR > 1 { found = 1 } { prev = $0 } END { exit !found }' "$f"; then
    echo "two blank lines in a row: $f"
    status=1
  fi
  if [[ -s "$f" && -z "$(tail -1 "$f" | tr -d '[:space:]')" ]]; then
    echo "extra blank line at end: $f"
    status=1
  fi
done
[[ "$status" == 0 ]] && echo "lint-lite: clean (${#files[@]} files)"
exit "$status"
