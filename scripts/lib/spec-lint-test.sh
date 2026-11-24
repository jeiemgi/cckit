#!/usr/bin/env bash
# spec-lint-test.sh — the `## Spec` check (scripts/lib/spec-lint.sh, E546.5): an accept/reject table
# over effort bodies, the reasons it prints, and spec_section, the body builder `effort new` uses.
# Hermetic, no network.
# errors: strict — a test runner: rc 1 on any failed assertion
set -u
LIB="$(cd "$(dirname "$0")" && pwd)"
fail=0
# shellcheck source=/dev/null
. "$LIB/spec-lint.sh"

t()   { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1"; echo "     got:  [$2]"; echo "     want: [$3]"; fail=1; fi; }
acc() { if spec_lint "$2" >/dev/null 2>&1; then echo "ok   accepts: $1"; else echo "FAIL should accept: $1"; spec_lint "$2"; fail=1; fi; }
rej() { if spec_lint "$2" >/dev/null 2>&1; then echo "FAIL should reject: $1"; fail=1; else echo "ok   rejects: $1"; fi; }
nl='
'

# --- accept ---
acc "one bullet"                 "## Spec${nl}- the verb refuses a body without a Spec"
acc "numbered items"             "## Goal${nl}ship${nl}${nl}## Spec${nl}1. new refuses${nl}2) close refuses${nl}${nl}## Scope${nl}x"
acc "star and plus bullets"      "## Spec${nl}* one${nl}+ two"
acc "a checkbox item"            "## Spec${nl}- [ ] close re-reads the body"
acc "a sub-heading inside"       "## Spec${nl}### Verbs${nl}- new lints it"
acc "a real item beside a TODO"  "## Spec${nl}- TODO${nl}- the lint has a test table"
acc "trailing spaces on heading" "## Spec  ${nl}- done means merged"
acc "CRLF line endings"          "## Spec$(printf '\r')${nl}- done means merged$(printf '\r')"

# --- reject ---
rej "an empty body"              ""
rej "no Spec heading"            "## Goal${nl}- ship it"
rej "a level-3 Spec heading"     "### Spec${nl}- ship it"
rej "an empty section"           "## Spec${nl}${nl}## Scope${nl}- x"
rej "prose but no list item"     "## Spec${nl}It is done when it works."
rej "TODO only"                  "## Spec${nl}- TODO"
rej "TBD and placeholders"       "## Spec${nl}- TBD${nl}- todo: write this${nl}1. ...${nl}- ?"
rej "an HTML comment only"       "## Spec${nl}<!-- what done means -->"
rej "a commented-out item"       "## Spec${nl}<!-- - the verb refuses -->"
rej "an empty bullet"            "## Spec${nl}-${nl}- "
rej "items only after the next heading" "## Spec${nl}${nl}## Scope${nl}- a scope item"

# --- reasons on stderr, nothing on stdout ---
err="$(spec_lint "## Goal${nl}x" 2>&1 >/dev/null)"
case "$err" in *"no '## Spec' section"*) echo "ok   names a missing heading" ;; *) echo "FAIL missing-heading reason: $err"; fail=1 ;; esac
err="$(spec_lint "## Spec${nl}prose" 2>&1 >/dev/null)"
case "$err" in *"no list item"*) echo "ok   names an empty section" ;; *) echo "FAIL empty-section reason: $err"; fail=1 ;; esac
err="$(spec_lint "## Spec${nl}- TBD" 2>&1 >/dev/null)"
case "$err" in *"placeholder"*) echo "ok   names a placeholder-only section" ;; *) echo "FAIL placeholder reason: $err"; fail=1 ;; esac
t "stdout stays empty on a refusal" "$(spec_lint "## Goal" 2>/dev/null)" ""
spec_lint "## Spec${nl}- ok" >/dev/null 2>&1; t "rc 0 on a clean body" "$?" "0"
spec_lint "## Goal" >/dev/null 2>&1;          t "rc 1 on a refusal"    "$?" "1"
spec_lint >/dev/null 2>&1;                    t "rc 2 with no argument" "$?" "2"
t "reads the body from stdin with -" "$(printf '## Spec\n- piped\n' | spec_lint - >/dev/null 2>&1; echo $?)" "0"

# --- spec_section: the section effort new writes ---
t "plain lines become bullets" "$(spec_section "close refuses${nl}new refuses")" "## Spec${nl}- close refuses${nl}- new refuses"
t "a list is kept as written"  "$(spec_section "1. first${nl}2. second")" "## Spec${nl}1. first${nl}2. second"
t "blank lines are dropped"    "$(spec_section "${nl}one${nl}${nl}")" "## Spec${nl}- one"
t "an empty spec gives the heading only" "$(spec_section "")" "## Spec"
spec_lint "$(spec_section "the gate is green")" >/dev/null 2>&1; t "a built section passes the lint" "$?" "0"
spec_lint "$(spec_section "TODO")" >/dev/null 2>&1;              t "a built TODO fails the lint"     "$?" "1"

[ "$fail" = 0 ] && echo "spec-lint-test: all ok" || echo "spec-lint-test: FAILURES"
exit "$fail"
