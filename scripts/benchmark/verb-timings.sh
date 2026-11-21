#!/usr/bin/env bash
# benchmark/verb-timings.sh — wall time and GitHub call count of cckit's read-only verbs (#452).
#
# Each verb runs --runs times (default 3) from one checkout. Per verb it records the fastest and the
# median wall time in milliseconds, and how many times the verb ran `gh`.
#
# Usage:
#   verb-timings.sh [--runs <N>] [--checkout <dir>] [--cckit <path>] [--verb "<verb> [args]"]… [--json]
#       --checkout  the directory the verbs run in (default: the current directory)
#       --cckit     the CLI to measure (default: <checkout>/bin/cckit, else the cckit this script ships in)
#       --verb      measure this verb and not the default list; repeatable
#       --json      print one JSON object: { kind: "verb-timings", date, commit, runs,
#                   verbs: [ { verb, runs, min_ms, median_ms, gh_calls, exit } ] }
#                   (`cckit bench checkpoint <X.Y.Z> --verbs <that file>` attaches it to a checkpoint)
#
# The default list is the verbs that change no branch, worktree, tracked file, issue, PR or board:
#   status · sync · next · plan · gc · effort plan · claims · task list · qa lanes
# Three of them still touch the shared git directory: `status`, `gc` and `task list` refresh the
# remote-tracking refs (`git fetch --prune`), and `sync` appends two lines to kit-events.jsonl.
#
# How `gh` is counted: a shim named `gh` in a temp dir is put first on PATH of each measured verb,
# and only there. It appends one line to a log and execs the real `gh` with the same arguments, so
# the verb's behaviour and output are unchanged. The temp dir is removed when the script exits; the
# shell that called this script keeps its PATH. `gh_calls` is the median count across the runs.
#
# A verb that exits non-zero is still timed; its highest exit code is recorded as `exit` so a
# failed verb is not read as a fast one. Timings taken while other work runs on the machine are
# not comparable between checkpoints: take them on an idle machine.
#
# Exit: 0 measured · 2 usage error, or perl/jq missing, or no cckit to measure.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KIT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; }

DEFAULT_VERBS='status
sync
next
plan
gc
effort plan
claims
task list
qa lanes'

runs=3; checkout=""; cckit=""; json=0; verbs=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --runs|--checkout|--cckit|--verb)
      [ "$#" -ge 2 ] || { echo "verb-timings: $1 needs a value" >&2; exit 2; } ;;
  esac
  case "$1" in
    --runs)       runs="$2"; shift 2 ;;
    --runs=*)     runs="${1#*=}"; shift ;;
    --checkout)   checkout="$2"; shift 2 ;;
    --checkout=*) checkout="${1#*=}"; shift ;;
    --cckit)      cckit="$2"; shift 2 ;;
    --cckit=*)    cckit="${1#*=}"; shift ;;
    --verb)       verbs="${verbs}${2}
"; shift 2 ;;
    --verb=*)     verbs="${verbs}${1#*=}
"; shift ;;
    --json|--llm) json=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *)            echo "verb-timings: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

grep -Eq '^[1-9][0-9]*$' <<<"$runs" || { echo "verb-timings: --runs must be a positive integer" >&2; exit 2; }
command -v jq >/dev/null 2>&1   || { echo "verb-timings: jq is required" >&2; exit 2; }
command -v perl >/dev/null 2>&1 || { echo "verb-timings: perl is required (millisecond clock)" >&2; exit 2; }

[ -n "$checkout" ] || checkout="$PWD"
[ -d "$checkout" ] || { echo "verb-timings: no such checkout: $checkout" >&2; exit 2; }
checkout="$(cd "$checkout" && pwd)"
if [ -z "$cckit" ]; then
  cckit="$checkout/bin/cckit"; [ -f "$cckit" ] || cckit="$KIT_ROOT/bin/cckit"
fi
[ -f "$cckit" ] || { echo "verb-timings: no cckit to measure at $cckit" >&2; exit 2; }
[ -n "$verbs" ] || verbs="$DEFAULT_VERBS"

# An explicit template: a bare `mktemp -d` ignores TMPDIR on macOS.
_td="${TMPDIR:-/tmp}"; tmp="$(mktemp -d "${_td%/}/verb-timings.XXXXXX")" || exit 2
# shellcheck disable=SC2064
trap "rm -rf '$tmp'" EXIT

# The shim. GH_SHIM_REAL is resolved here, before the shim dir is on any PATH, so the shim can
# never exec itself. With no gh installed the shim still counts the call and exits 127, which is
# what the verb would have got from the shell.
real_gh="$(command -v gh 2>/dev/null || true)"
mkdir -p "$tmp/shim"
cat > "$tmp/shim/gh" <<'SHIM'
#!/bin/sh
printf '%s\n' "${1:-}" >> "$GH_SHIM_LOG"
[ -n "${GH_SHIM_REAL:-}" ] || { echo "gh: command not found" >&2; exit 127; }
exec "$GH_SHIM_REAL" "$@"
SHIM
chmod +x "$tmp/shim/gh"

# One run: perl takes the clock on both sides of the verb, so the only process start inside the
# measured interval is the verb's own. Writes "<ms> <exit>" to the file named first; the verb's
# own output is discarded by the caller.
TIMER='my $out = shift; my $t = time; system(@ARGV);
my $rc = ($? & 127) ? 128 + ($? & 127) : ($? >> 8);
open(my $f, ">", $out) or exit 2; printf $f "%d %d\n", (time - $t) * 1000, $rc; close $f;'

rows="$tmp/rows.jsonl"; : > "$rows"
while IFS= read -r verb; do
  [ -n "$verb" ] || continue
  times=""; calls=""; worst=0; i=0
  while [ "$i" -lt "$runs" ]; do
    i=$((i+1))
    log="$tmp/gh.log"; : > "$log"
    : > "$tmp/t"
    # shellcheck disable=SC2086  # the verb string is split into words on purpose: "effort plan"
    ( cd "$checkout" && env PATH="$tmp/shim:$PATH" GH_SHIM_LOG="$log" GH_SHIM_REAL="$real_gh" \
        perl -MTime::HiRes=time -e "$TIMER" "$tmp/t" bash "$cckit" $verb </dev/null >/dev/null 2>&1 )
    res="$(cat "$tmp/t")"
    grep -Eq '^[0-9]+ [0-9]+$' <<<"$res" || { echo "verb-timings: could not time 'cckit $verb'" >&2; exit 2; }
    ms="${res%% *}"; rc="${res##* }"
    n="$(wc -l < "$log" | tr -d ' ')"
    times="${times}${ms}
"
    calls="${calls}${n}
"
    [ "$rc" -gt "$worst" ] && worst="$rc"
    [ "$json" -eq 1 ] || printf '  %-12s run %s/%s  %s ms  %s gh call(s)  exit %s\n' "$verb" "$i" "$runs" "$ms" "$n" "$rc" >&2
  done
  jq -n -c --arg verb "$verb" --argjson runs "$runs" --argjson exit "$worst" \
        --arg times "$times" --arg calls "$calls" '
    def nums(s): [ s | split("\n")[] | select(length > 0) | tonumber ] | sort;
    def median: if length % 2 == 1 then .[(length - 1) / 2] else ((.[length / 2 - 1] + .[length / 2]) / 2 | floor) end;
    nums($times) as $t | nums($calls) as $c
    | { verb: $verb, runs: $runs, min_ms: $t[0], median_ms: ($t | median), gh_calls: ($c | median), exit: $exit }' >> "$rows"
done <<<"$verbs"

commit="$(git -C "$checkout" rev-parse --short HEAD 2>/dev/null || true)"
doc="$(jq -s -c --arg date "$(date +%Y-%m-%d)" --arg commit "$commit" --argjson runs "$runs" \
  '{ kind: "verb-timings", date: $date, commit: $commit, runs: $runs, verbs: . }' "$rows")" || exit 2

if [ "$json" -eq 1 ]; then
  printf '%s\n' "$doc"
else
  printf '%-14s %5s %9s %10s %9s %5s\n' "VERB" "RUNS" "MIN_MS" "MEDIAN_MS" "GH_CALLS" "EXIT"
  printf '%s' "$doc" | jq -r '.verbs[] | [.verb, .runs, .min_ms, .median_ms, .gh_calls, .exit] | @tsv' \
    | while IFS='	' read -r v r mn md g x; do printf '%-14s %5s %9s %10s %9s %5s\n' "$v" "$r" "$mn" "$md" "$g" "$x"; done
fi
