#!/usr/bin/env bash
# test-env-test.sh — test_env_seal removes the caller's kit environment, and only that (#369).
# Run: bash scripts/lib/test-env-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
set -u
LIB="$(cd "$(dirname "$0")" && pwd)"
fail=0
t() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }

out="$(KIT_CONFIG=/nonexistent CCKIT_OUTPUT=json EFFORT_REPO=x/y KEEP_ME=1 bash -c '
  . "$1/test-env.sh"
  test_env_unset_args | paste -sd" " -
  test_env_seal
  echo "${KIT_CONFIG-unset} ${CCKIT_OUTPUT-unset} ${EFFORT_REPO-unset} ${KEEP_ME-unset}"' _ "$LIB")"
args="$(printf '%s\n' "$out" | sed -n 1p)"
after="$(printf '%s\n' "$out" | sed -n 2p)"
case " $args " in *" -u KIT_CONFIG "*) echo "ok: unset args name KIT_CONFIG" ;; *) echo "FAIL: unset args: $args"; fail=1 ;; esac
case " $args " in *" -u KEEP_ME "*) echo "FAIL: unset args name a non-kit variable: $args"; fail=1 ;; *) echo "ok: unset args leave other variables alone" ;; esac
t "seal unsets KIT_*, CCKIT_*, EFFORT_* and keeps the rest" "$after" "unset unset unset 1"

# The runner seals too: a test run under scripts/test.sh never sees the caller's KIT_CONFIG.
if [ -n "${KIT_CONFIG:-}" ]; then echo "FAIL: KIT_CONFIG leaked into this test"; fail=1; else echo "ok: no KIT_CONFIG reached this test"; fi

[ "$fail" -eq 0 ] && echo "test-env: all passed" || echo "test-env: FAILURES"
exit "$fail"
