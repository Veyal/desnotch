#!/bin/bash
# Copies the files one work package owns from its (detached) worktree into the feat/voice
# worktree. The packages own disjoint paths (ownership.tsv), so copying exactly the owned
# paths is equivalent to a merge, and no branch is ever created or merged.
#
# usage (run from the root of the feat/voice worktree):
#   scripts/voice-harness/import-wp.sh <WP-LOGIC|WP-UI|WP-PLATFORM|WP-HERMES> <path-to-package-worktree>
#
# It prints one `git add` path per line (the files it copied or changed). It never runs git.
# Run check-ownership.sh in the package worktree FIRST; this script refuses a path that is
# not owned by the package.
set -euo pipefail

repo="$(cd "$(dirname "$0")/../.." && pwd)"
wp="${1:?usage: import-wp.sh <WP-NAME> <package-worktree>}"
src="${2:?usage: import-wp.sh <WP-NAME> <package-worktree>}"
table="$repo/scripts/voice-harness/ownership.tsv"

case "$wp" in
  WP-LOGIC|WP-UI|WP-PLATFORM|WP-HERMES) ;;
  *) echo "unknown package: $wp" >&2; exit 64 ;;
esac
[[ -d "$src" && "$src" != "$repo" ]] || { echo "bad package worktree: $src" >&2; exit 64; }

copied=0
while IFS= read -r path; do
  [[ -z "$path" ]] && continue
  [[ -f "$src/$path" ]] || continue
  if [[ -f "$repo/$path" ]] && cmp -s "$src/$path" "$repo/$path"; then
    continue
  fi
  mkdir -p "$(dirname "$repo/$path")"
  cp "$src/$path" "$repo/$path"
  echo "$path"
  copied=$((copied + 1))
done < <(awk -F'\t' -v wp="$wp" '$2 == wp { print $1 }' "$table")

echo "import-wp: $copied file(s) copied for $wp" >&2
