#!/usr/bin/env bash
# shellcheck shell=bash
# effort-metrics-test.sh — covers _em_token_sum's branch ∪ time-window attribution (#124). Token
# actuals must count sessions that match the effort BRANCH as well as sessions that fall inside the
# effort's build WINDOW [start,end] — the window recovers sessions logged before the branch field
# existed or from a detached/worktree checkout. Hermetic: a throwaway repo + a stubbed usage log +
# stubbed transcripts under a temp HOME. Run:  bash scripts/lib/effort-metrics-test.sh
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$ROOT/scripts/lib"
fail=0
t() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fi; [ "$2" = "$3" ] || fail=1; }
command -v jq >/dev/null 2>&1 || { echo "effort-metrics-test: jq required — skipping"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "effort-metrics-test: git required" >&2; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"; mkdir -p "$HOME/.claude/projects"

# A repo so git-common-dir resolves; kit-usage.jsonl lives under it.
cd "$tmp"; git init -q repo; cd repo; git config user.email t@t; git config user.name t
git commit -q --allow-empty -m init
GCD="$(git rev-parse --git-common-dir)"; case "$GCD" in /*) : ;; *) GCD="$PWD/$GCD" ;; esac

# Usage log: A matches the branch; B matches the window (different branch, ts inside); C matches
# neither (different branch, ts outside the window).
START=1000000000; END=1000000900     # a 900s window
{
  printf '{"session":"AAA","branch":"effort/5-x","ts":"2001-09-09T01:46:20Z"}\n'   # branch match (ts irrelevant)
  printf '{"session":"BBB","branch":"other/9-y","ts":"2001-09-09T01:55:00Z"}\n'    # ~1000000500 — inside window
  printf '{"session":"CCC","branch":"other/9-z","ts":"2020-01-01T00:00:00Z"}\n'    # far outside window
} > "$GCD/kit-usage.jsonl"

# Transcripts: A=100 in, B=50 in, C=999 in. Only A+B should be counted.
printf '{"message":{"usage":{"input_tokens":100,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' > "$HOME/.claude/projects/AAA.jsonl"
printf '{"message":{"usage":{"input_tokens":50,"output_tokens":5,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n'  > "$HOME/.claude/projects/BBB.jsonl"
printf '{"message":{"usage":{"input_tokens":999,"output_tokens":99,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' > "$HOME/.claude/projects/CCC.jsonl"

# shellcheck source=/dev/null
source "$LIB/effort-metrics.sh"

# branch only: counts A (100/10); window given but branch alone would miss B if window absent.
read -r i o _ _ <<< "$(_em_token_sum 'effort/5-x' 0 0)"
t "branch-only counts the branch session"      "$i $o" "100 10"

# branch ∪ window: counts A (branch) + B (window) = 150 in / 15 out; C excluded (outside window).
read -r i o _ _ <<< "$(_em_token_sum 'effort/5-x' "$START" "$END")"
t "branch ∪ window counts branch + window sessions" "$i $o" "150 15"

# window only (no branch): counts just B (inside window), never C.
read -r i o _ _ <<< "$(_em_token_sum '' "$START" "$END")"
t "window-only counts the in-window session"   "$i $o" "50 5"

# no branch, no window: nothing attributable.
t "no branch + no window sums to zero"          "$(_em_token_sum '' 0 0)" "0 0 0 0"

[ "$fail" -eq 0 ] && echo "ALL OK (effort-metrics)" || echo "effort-metrics: FAILURES"
exit "$fail"
