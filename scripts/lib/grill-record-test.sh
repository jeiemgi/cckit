#!/usr/bin/env bash
# grill-record-test.sh — the `## Grilling` record check (scripts/lib/grill-record.sh, E547.2): an
# accept/reject table, the reasons it prints, and grill_record_section. Hermetic, no network.
# errors: strict — a test runner: rc 1 on any failed assertion
set -u
LIB="$(cd "$(dirname "$0")" && pwd)"
fail=0
# shellcheck source=/dev/null
. "$LIB/grill-record.sh"

t()   { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1"; echo "     got:  [$2]"; echo "     want: [$3]"; fail=1; fi; }
acc() { if grill_record_lint "$2" >/dev/null 2>&1; then echo "ok   accepts: $1"; else echo "FAIL should accept: $1"; grill_record_lint "$2"; fail=1; fi; }
rej() { if grill_record_lint "$2" >/dev/null 2>&1; then echo "FAIL should reject: $1"; fail=1; else echo "ok   rejects: $1"; fi; }
nl='
'
rec="Grilled: the maintainer, 2026-11-24, in session.${nl}1. One sprint is one week.${nl}2. Waves run inside a sprint.${nl}3. The advisor writes no code."

# --- accept ---
acc "three numbered decisions"       "$rec"
acc "paren-numbered decisions"       "Grilled: the owner, 2026-11-24.${nl}1) a${nl}2) b${nl}3) c"
acc "continuation lines indented"    "$rec${nl}   because it keeps the review weekly"
acc "a comment link holds them"      "Grilled: the owner, 2026-11-24.${nl}Decisions: https://github.com/o/r/issues/12#issuecomment-345"
acc "an assumed record"              "Grilled: the agent (assumed), 2026-11-24.${nl}1. a${nl}2. b${nl}3. c"
acc "a waiver"                       "waived: a one-line rename, nothing to decide"
acc "leading blank lines and CRLF"   "${nl}${nl}Grilled: the owner, 2026-11-24.$(printf '\r')${nl}1. a${nl}2. b${nl}3. c"

# --- reject ---
rej "an empty record"                ""
rej "no Grilled line"                "2026-11-24${nl}1. a${nl}2. b${nl}3. c"
rej "Grilled names nobody"           "Grilled:${nl}2026-11-24${nl}1. a${nl}2. b${nl}3. c"
rej "no date"                        "Grilled: the owner.${nl}1. a${nl}2. b${nl}3. c"
rej "two decisions"                  "Grilled: the owner, 2026-11-24.${nl}1. a${nl}2. b"
rej "indented items do not count"    "Grilled: the owner, 2026-11-24.${nl}  1. a${nl}  2. b${nl}  3. c"
rej "an issue link is not a record"  "Grilled: the owner, 2026-11-24.${nl}See https://github.com/o/r/issues/12"
rej "a waiver with no reason"        "waived:"
rej "a waiver among other lines"     "waived: x${nl}1. a"

# --- the reasons name what is missing ---
err="$(grill_record_lint "Grilled: the owner.${nl}1. a" 2>&1 >/dev/null)"
case "$err" in *"no YYYY-MM-DD date"*) echo "ok   reason: missing date" ;; *) echo "FAIL reason: missing date — got: $err"; fail=1 ;; esac
case "$err" in *"1 decision(s)"*) echo "ok   reason: counts the decisions" ;; *) echo "FAIL reason: decision count — got: $err"; fail=1 ;; esac
grill_record_lint >/dev/null 2>&1; t "no argument is a usage error" "$?" "2"
printf '%s\n' "$rec" | grill_record_lint - >/dev/null 2>&1; t "reads stdin with -" "$?" "0"

# --- the section builder ---
t "section: heading, blank, text, blank edges cut" \
  "$(grill_record_section "${nl}${nl}waived: rename${nl}${nl}")" "## Grilling${nl}${nl}waived: rename"

exit "$fail"
