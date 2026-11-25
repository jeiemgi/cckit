#!/usr/bin/env bash
# shellcheck shell=bash
# effort-dispatch-test.sh — #151: the `effort)` dispatcher branch in bin/cckit must load the project
# config BEFORE sourcing/dispatching the effort libs. It shipped without it, so KIT_BASE_BRANCH was
# unset, `_eff_base` fell back to main, and `cckit effort start` silently created worktrees from
# origin/main on a non-main-based repo (and the KIT_PROJECTS_V2 board guard never fired via the CLI).
# Static contract test over bin/cckit: extract the branch block, assert load_kit_config comes first.
# Run:  bash lib/verbs/effort-dispatch-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$ROOT/bin/cckit"
fail=0
t() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }

# The effort) branch: from its case label to its terminating `;;` at branch indentation.
blk="$(awk '/^  effort\)/{f=1} f{print} f && /^    ;;$/{exit}' "$BIN")"
t "effort) branch found" "$([ -n "$blk" ] && echo yes)" "yes"

cfg_ln="$(printf '%s\n' "$blk" | grep -n 'load_kit_config' | sed -n 1p | cut -d: -f1)"
lib_ln="$(printf '%s\n' "$blk" | grep -n 'source "\$LIB/core/effort\.sh"' | sed -n 1p | cut -d: -f1)"
t "effort) loads the project config"          "$([ -n "$cfg_ln" ] && echo yes)" "yes"
t "config load precedes the effort libs"      "$([ -n "$cfg_ln" ] && [ -n "$lib_ln" ] && [ "$cfg_ln" -lt "$lib_ln" ] && echo yes)" "yes"

# #243: every effort subcommand the usage advertises must actually dispatch, `chain` included
# — a docs/code drift guard (a subcommand documented but not wired falls through to the usage line).
# The usage lives in the verb table (#555): one `cckit effort <sub>` line per subcommand.
usage_subs="$(awk -F'\t' '$1 == "effort" && $2 == "verb" { print $10 }' "$(dirname "$BIN")/../lib/core/verbs.tsv" \
  | sed 's/\\n/\n/g' | awk '$1 == "cckit" && $2 == "effort" && !seen[$3]++ { printf "%s%s", sep, $3; sep = " " }')"
t "the verb table's usage lists the effort subcommands" "$usage_subs" "new sub retitle chain start pr close plan sprint review"
for s in $usage_subs; do
  t "effort) dispatches '$s'" \
    "$(printf '%s\n' "$blk" | grep -cE "^      ${s}\)" | tr -d ' ')" "1"
done

[ "$fail" -eq 0 ] && echo "ALL OK"
exit "$fail"
