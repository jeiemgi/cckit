#!/usr/bin/env bash
# layout-fence.sh — the repo layout ratchet (#605, decisions 45 and 55).
#   1. Every top-level directory is on the allowlist in lib/core/layout-fence.allow. A new one fails:
#      add it to the allowlist in the same change, or put the files under an existing layer.
#   2. The retired roots (the old install-payload directories, now under kit/) hold no tracked path.
#   3. Ratchet counts in lib/core/layout-fence.baseline: the files directly under scripts/ and directly
#      under scripts/lib/ may not grow. A drop must lower the baseline in the same change, so the
#      ratchet never goes slack.
# Counts read tracked files (git ls-files), so the check matches CI. Run from anywhere in the repo.
#   bash lib/core/layout-fence.sh [--root <dir>]
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
[ "${1:-}" = "--root" ] && { ROOT="$(cd "${2:?--root needs a directory}" && pwd)"; }
cd "$ROOT" || exit 2
ALLOW="lib/core/layout-fence.allow"; BASE="lib/core/layout-fence.baseline"
[ -f "$ALLOW" ] && [ -f "$BASE" ] || { echo "layout-fence: missing $ALLOW or $BASE" >&2; exit 2; }
fail=0
x() { echo "x layout: $*"; fail=1; }

allowed="$(grep -vE '^[[:space:]]*(#|$)' "$ALLOW" | sed 's#/*$##')"
while IFS= read -r d; do
  [ -n "$d" ] || continue
  grep -qxF -- "$d" <<< "$allowed" || x "top-level directory '$d/' is not on the allowlist ($ALLOW)"
done < <(git ls-files | awk -F/ 'NF>1{print $1}' | sort -u)

for r in templates skills profiles integrations commands modules recipes routines interview databases statusline completions githooks; do
  n="$(git ls-files -- "$r" "$r/*" | wc -l | tr -d ' ')"
  [ "$n" -eq 0 ] || x "retired root '$r' holds $n tracked path(s); it lives under kit/$r now"
done

# The layer's PROMPTS.md (its rules) is not code waiting to move, so it does not count.
count() { git ls-files -- "$1" | awk -F/ -v n="$2" 'NF==n && $NF!="PROMPTS.md"' | wc -l | tr -d ' '; }
check() { # <key> <now>
  local want; want="$(awk -v k="$1" '$1==k{print $2}' "$BASE")"
  [ -n "$want" ] || { x "no '$1' line in $BASE"; return; }
  if [ "$2" -gt "$want" ]; then x "$1: $2 files, baseline $want — put new files under a lib/ layer, not here"
  elif [ "$2" -lt "$want" ]; then x "$1: $2 files, baseline $want — lower the baseline to $2 in this change"
  else echo "ok layout: $1 $2"; fi
}
check scripts-top "$(count scripts 2)"
check scripts-lib "$(count scripts/lib 3)"
[ "$fail" -eq 0 ] && echo "ok layout: $(echo "$allowed" | wc -l | tr -d ' ') allowed top-level directories"
exit "$fail"
