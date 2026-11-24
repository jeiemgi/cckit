#!/usr/bin/env bash
# verbs-ratchet.sh — the top-level verb count may only go down (#557).
#
# Counts the `verb` rows of scripts/lib/verbs.tsv (old names, `alias` rows, do not count) and
# compares the count with the number in scripts/verbs.baseline:
#   more than the baseline  FAIL — a new top-level verb; add it as a subcommand of one that exists
#   fewer than the baseline FAIL — lower the baseline to the new count in the same change
#   equal                   ok
# A rename is the alias path: the old name becomes an `alias` row and keeps working, so a rename
# never changes the count. The ratchet only moves down.
#
# Usage: bash scripts/verbs-ratchet.sh [--root <dir>]
# errors: strict — a gate: rc 1 on drift, rc 2 on a missing or malformed baseline
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
[ "${1:-}" = "--root" ] && root="$2"
baseline_file="$root/scripts/verbs.baseline"
# shellcheck source=/dev/null
source "$root/scripts/lib/verbs.sh"
export VERBS_FILE="$root/scripts/lib/verbs.tsv"

base="$(awk '!/^#/ && NF { print $1; exit }' "$baseline_file" 2>/dev/null)"
case "$base" in ''|*[!0-9]*) echo "x verbs ratchet: no number in $baseline_file" >&2; exit 2 ;; esac
now="$(verbs_count)"

if [ "$now" -gt "$base" ]; then
  echo "x verbs ratchet: $now top-level verbs, the baseline is $base. A new verb goes under an existing one (\`cckit <verb> <sub>\`); the top level only shrinks." >&2
  exit 1
fi
if [ "$now" -lt "$base" ]; then
  echo "x verbs ratchet: $now top-level verbs, below the baseline of $base. Lower scripts/verbs.baseline to $now in this change." >&2
  exit 1
fi
echo "ok verbs ratchet: $now top-level verbs (baseline $base; it may only go down)"
