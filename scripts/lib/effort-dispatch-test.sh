#!/usr/bin/env bash
# shellcheck shell=bash
# effort-dispatch-test.sh — #151: the `effort)` dispatcher branch in bin/cckit must load the project
# config BEFORE sourcing/dispatching the effort libs. It shipped without it, so KIT_BASE_BRANCH was
# unset, `_eff_base` fell back to main, and `cckit effort start` silently created worktrees from
# origin/main on a non-main-based repo (and the KIT_PROJECTS_V2 board guard never fired via the CLI).
# Static contract test over bin/cckit: extract the branch block, assert load_kit_config comes first.
# Run:  bash scripts/lib/effort-dispatch-test.sh
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$ROOT/bin/cckit"
fail=0
t() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }

# The effort) branch: from its case label to its terminating `;;` at branch indentation.
blk="$(awk '/^  effort\)/{f=1} f{print} f && /^    ;;$/{exit}' "$BIN")"
t "effort) branch found" "$([ -n "$blk" ] && echo yes)" "yes"

cfg_ln="$(printf '%s\n' "$blk" | grep -n 'load_kit_config' | head -1 | cut -d: -f1)"
lib_ln="$(printf '%s\n' "$blk" | grep -n 'source "\$LIB/effort\.sh"' | head -1 | cut -d: -f1)"
t "effort) loads the project config"          "$([ -n "$cfg_ln" ] && echo yes)" "yes"
t "config load precedes the effort libs"      "$([ -n "$cfg_ln" ] && [ -n "$lib_ln" ] && [ "$cfg_ln" -lt "$lib_ln" ] && echo yes)" "yes"

[ "$fail" -eq 0 ] && echo "ALL OK"
exit "$fail"
