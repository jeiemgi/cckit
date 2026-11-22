#!/usr/bin/env bash
# forge-fence.sh — E537.5: the gate fails when a file outside the forge layer calls gh or the GitHub
# API. The layer is scripts/lib/forge.sh, scripts/lib/forge-*.sh and scripts/lib/gh-rest.sh; every
# other non-test file under bin/, scripts/ and scripts/lib/ (test doubles, scripts/lib/test-*.sh, are
# not code) reaches GitHub through forge_* / gh_rest_*.
#
#   scripts/forge-fence.sh              rc 0 when the count is at or under the baseline, 1 over it
#   scripts/forge-fence.sh --root <dir> fence another checkout
#   scripts/forge-fence.sh --write      write the current count into the baseline (a ratchet moves
#                                       down on its own; raising it is a decision, made here on purpose)
#
# Two counts, each a ratchet against scripts/forge-fence.baseline (`gh=<n>` and `api=<n>` lines):
#   gh   files outside the layer with a gh line, as scripts/forge-report.sh --ratchet counts them
#        (a gh <subcommand> in command position, a `gh "$…"` form, or a `command -v gh` probe)
#   api  files outside the layer whose non-comment lines name api.github.com (a curl to the API)
# The baseline starts at 0 for both (the count left after E537.3). A new offender fails the gate and
# is named with its lines; the fix is to call the layer.
# errors: strict — set -e; a missing report script or baseline exits 1
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
write=0
while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="$(cd "${2:?--root needs a directory}" && pwd)"; shift 2 ;;
    --write) write=1; shift ;;
    -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "forge-fence: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
report="$ROOT/scripts/forge-report.sh"
baseline="$ROOT/scripts/forge-fence.baseline"
[ -f "$report" ] || { echo "forge-fence: $report is missing" >&2; exit 1; }

is_layer() { case "$1" in scripts/lib/forge.sh|scripts/lib/forge-*.sh|scripts/lib/gh-rest.sh) return 0 ;; *) return 1 ;; esac; }

# gh: the report's own file table (its GH_RE), minus the layer.
gh_files="$(bash "$report" --root "$ROOT" --files | awk 'NR > 1 && $2 > 0 {print $1}' | while IFS= read -r f; do is_layer "$f" || printf '%s\n' "$f"; done)"
gh_n="$(printf '%s\n' "$gh_files" | sed '/^$/d' | wc -l | tr -d ' ')"

# api: a non-comment line naming the API host, outside the layer.
api_files="$(cd "$ROOT" && { for f in bin/*; do [ -f "$f" ] && echo "$f"; done; for f in scripts/*.sh scripts/lib/*.sh; do [ -f "$f" ] && echo "$f"; done; } \
  | grep -vE -- '-test\.sh$|^scripts/lib/test-[a-z-]+\.sh$' | sort -u | while IFS= read -r f; do
      is_layer "$f" && continue
      case "$f" in scripts/forge-fence.sh|scripts/forge-report.sh) continue ;; esac
      body="$(grep -vE '^[[:space:]]*#' "$f" || true)"
      if grep -q 'api\.github\.com' <<<"$body"; then printf '%s\n' "$f"; fi
    done)"
api_n="$(printf '%s\n' "$api_files" | sed '/^$/d' | wc -l | tr -d ' ')"

if [ "$write" = 1 ]; then
  printf 'gh=%s\napi=%s\n' "$gh_n" "$api_n" > "$baseline"
  echo "forge-fence: baseline written — gh=$gh_n api=$api_n"
  exit 0
fi
[ -f "$baseline" ] || { echo "forge-fence: no baseline at $baseline (run: scripts/forge-fence.sh --write)" >&2; exit 1; }
gh_max="$(sed -n 's/^gh=//p' "$baseline" | sed -n 1p)"; api_max="$(sed -n 's/^api=//p' "$baseline" | sed -n 1p)"
case "$gh_max$api_max" in *[!0-9]*|'') echo "forge-fence: the baseline must hold gh=<n> and api=<n>" >&2; exit 1 ;; esac

fail=0
if [ "$gh_n" -gt "$gh_max" ]; then
  fail=1
  echo "x forge fence: $gh_n file(s) outside the forge layer call gh (baseline $gh_max). Call the layer (forge_*, gh_rest_*) instead:"
  printf '%s\n' "$gh_files" | sed '/^$/d' | sed 's/^/    /'
fi
if [ "$api_n" -gt "$api_max" ]; then
  fail=1
  echo "x forge fence: $api_n file(s) outside the forge layer name api.github.com (baseline $api_max). Call forge_rest instead:"
  printf '%s\n' "$api_files" | sed '/^$/d' | sed 's/^/    /'
fi
if [ "$fail" = 0 ]; then
  echo "ok forge fence: gh $gh_n/$gh_max · api $api_n/$api_max files outside the layer"
  if [ "$gh_n" -lt "$gh_max" ] || [ "$api_n" -lt "$api_max" ]; then
    echo "   the count went down — ratchet it: scripts/forge-fence.sh --write"
  fi
fi
exit "$fail"
