#!/usr/bin/env bash
# test.sh — cckit behavioral test runner. Discovers every `*-test.sh` under bin/ and scripts/ and
# runs each as a self-contained test (a test exits non-zero on failure, prints its own ok/FAIL
# lines). Exits non-zero if any test fails. bash 3.2 compatible (no mapfile/associative arrays).
#
#   scripts/test.sh            run every discovered test
#   scripts/test.sh <pattern>  run only tests whose path matches <pattern> (grep -E)
#
# Folded into scripts/check.sh and run in CI (.github/workflows/test.yml).
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"

PATTERN="${1:-}"
note() { printf '%s\n' "$*" >&2; }

# Discover tests deterministically. Newline-separated, sorted, optionally filtered.
tests=()
while IFS= read -r f; do
  [ -n "$f" ] || continue
  [ -z "$PATTERN" ] || printf '%s\n' "$f" | grep -qE "$PATTERN" || continue
  tests+=("$f")
done < <(find bin scripts -type f -name '*-test.sh' 2>/dev/null | sort)

if [ "${#tests[@]}" -eq 0 ]; then
  note "test: no *-test.sh found${PATTERN:+ matching '$PATTERN'}"
  exit 0
fi

note "==> cckit tests — ${#tests[@]} file(s)${PATTERN:+ (filter: $PATTERN)}"
pass=0; failn=0; failed=""
for t in "${tests[@]}"; do
  out="$(bash "$t" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    pass=$((pass+1)); note "  ok   $t"
  else
    failn=$((failn+1)); failed="$failed$t"$'\n'
    note "  FAIL $t  (rc=$rc)"
    printf '%s\n' "$out" | sed 's/^/        /' >&2
  fi
done

note ""
note "==> $pass passed, $failn failed"
if [ "$failn" -ne 0 ]; then
  note "failed:"; printf '%s' "$failed" | sed 's/^/  - /' >&2
  exit 1
fi
note "PASS all tests"
