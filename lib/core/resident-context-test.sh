#!/usr/bin/env bash
# shellcheck shell=bash
# resident-context-test.sh — the resident-context ratchet (lib/core/resident-context.sh): the repo
# is within its baseline, and a fixture fails at exactly one byte over.
# Run:  bash lib/core/resident-context-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RC="$ROOT/lib/core/resident-context.sh"
fail=0
t() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }

# The repository itself: within its committed baseline.
out="$(bash "$RC" 2>&1)"; r=$?
t "the repo is within lib/core/resident-context.baseline${out:+ ($out)}" "$r" "0"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fx="$tmp/fx"; mkdir -p "$fx/lib/core" "$fx/.claude/rules"
cp "$ROOT/lib/core/resident-context.sh" "$ROOT/lib/core/instruction-budget-lint.sh" "$fx/lib/core/"
printf 'agents\n' > "$fx/AGENTS.md"                                          # 7 bytes
printf 'rule\n' > "$fx/.claude/rules/always.md"                              # 5 bytes, resident
printf -- '---\npaths:\n  - "docs/**"\n---\nscoped\n' > "$fx/.claude/rules/scoped.md"   # not counted
run() { RESIDENT_CONTEXT_ROOT="$fx" bash "$fx/lib/core/resident-context.sh" "$@" 2>&1; }

t "counts AGENTS.md and resident rules, not a path-scoped rule" "$(run --bytes)" "12"
run --update >/dev/null
t "--update writes the current total" "$(cat "$fx/lib/core/resident-context.baseline")" "12"
run >/dev/null; t "at the baseline -> rc 0" "$?" "0"
printf 'x' >> "$fx/AGENTS.md"
out="$(run)"; r=$?
t "one byte over the baseline -> rc 1" "$r" "1"
t "the failure names both numbers" "$(printf '%s' "$out" | grep -c 'grew to 13 bytes, over the baseline of 12')" "1"
printf 'x' >> "$fx/.claude/rules/scoped.md"
run --update >/dev/null; printf '%s\n' 20 > "$fx/lib/core/resident-context.baseline"
out="$(run)"; r=$?
t "under the baseline -> rc 0" "$r" "0"
t "under the baseline -> asks for it to be lowered" "$(printf '%s' "$out" | grep -c 'lower it')" "1"
rm "$fx/lib/core/resident-context.baseline"
run >/dev/null; t "no baseline -> rc 2" "$?" "2"

[ "$fail" -eq 0 ] && echo "resident-context: ok" || echo "resident-context: FAILURES"
exit "$fail"
