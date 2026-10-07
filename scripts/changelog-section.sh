#!/bin/bash
# Prints the body of one CHANGELOG.md release section to stdout.
#   scripts/changelog-section.sh 0.10.0     # body under "## v0.10.0 — <date>"
#   scripts/changelog-section.sh Unreleased # body under "## Unreleased"
# Exits non-zero when the heading is missing or the section is empty, so a release
# cannot be cut for a version the changelog does not describe.
set -euo pipefail

cd "$(dirname "$0")/.."

[[ $# -eq 1 && -n "$1" ]] || { echo "usage: $0 VERSION|Unreleased" >&2; exit 2; }
CHANGELOG="${CHANGELOG:-CHANGELOG.md}"
[[ -f "$CHANGELOG" ]] || { echo "error: $CHANGELOG not found" >&2; exit 1; }

version="${1#v}"
if [[ "$version" == "Unreleased" ]]; then
  heading="## Unreleased"
else
  [[ "$version" =~ ^[0-9]+(\.[0-9]+)*$ ]] || { echo "error: version must be dotted numeric (got '$version')" >&2; exit 2; }
  heading="## v$version"
fi

section="$(awk -v heading="$heading" '
  !found && index($0, heading) == 1 {
    rest = substr($0, length(heading) + 1)
    if (rest == "" || rest ~ /^[ \t]/) { found = 1; next }
  }
  found && /^## / { exit }
  found { print }
' "$CHANGELOG")"

# Drop leading blank lines (command substitution already strips trailing ones).
section="$(printf '%s\n' "$section" | sed -e '/./,$!d')"

[[ -n "$section" ]] || { echo "error: no '$heading' section (or it is empty) in $CHANGELOG" >&2; exit 1; }
printf '%s\n' "$section"
