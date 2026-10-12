#!/bin/bash
# Verifies that a worktree only touches files owned by one work package.
#
# usage: scripts/voice-harness/check-ownership.sh <WP-LOGIC|WP-UI|WP-PLATFORM|WP-HERMES> [base-ref]
#
# "Touched" = modified/added/deleted/untracked relative to base-ref (default HEAD, i.e. the
# uncommitted work of an implementer; pass the plan commit to check committed work too).
# The owner of each path comes from scripts/voice-harness/ownership.tsv (path<TAB>owner).
# Exit 0 when every touched path is owned by the package, 1 otherwise.
set -euo pipefail

repo="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo"

wp="${1:?usage: check-ownership.sh <WP-LOGIC|WP-UI|WP-PLATFORM|WP-HERMES> [base-ref]}"
base="${2:-HEAD}"
table="scripts/voice-harness/ownership.tsv"
[[ -f "$table" ]] || { echo "missing $table" >&2; exit 2; }

case "$wp" in
  WP-LOGIC|WP-UI|WP-PLATFORM|WP-HERMES) ;;
  *) echo "unknown package: $wp" >&2; exit 64 ;;
esac

status=0
touched="$({ git diff --name-only "$base"; git ls-files --others --exclude-standard; } | sort -u)"
count=0
while IFS= read -r path; do
  [[ -z "$path" ]] && continue
  count=$((count + 1))
  owner="$(awk -F'\t' -v p="$path" '$1 == p { print $2 }' "$table")"
  if [[ -z "$owner" ]]; then
    echo "NOT IN ANY PACKAGE'S FILE LIST: $path"
    status=1
  elif [[ "$owner" != "$wp" ]]; then
    echo "OWNED BY $owner, NOT $wp: $path"
    status=1
  fi
done <<<"$touched"

if [[ "$status" == 0 ]]; then
  echo "check-ownership: $wp touches $count file(s), all owned by $wp"
fi
exit "$status"
