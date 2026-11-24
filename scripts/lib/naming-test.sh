#!/usr/bin/env bash
# naming-test.sh — the one title convention (scripts/lib/naming.sh, E546.1): accept/reject tables
# per kind, the token parser, the prefix strip over new and legacy titles, and the wrappers
# effort_title_lint / effort_pr_title_check that keep legacy titles valid. Hermetic, no network.
# errors: strict — a test runner: rc 1 on any failed assertion
set -u
LIB="$(cd "$(dirname "$0")" && pwd)"
fail=0
# shellcheck source=/dev/null
. "$LIB/naming.sh"

t()   { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1"; echo "     got:  [$2]"; echo "     want: [$3]"; fail=1; fi; }
acc() { if naming_title_lint "$1" "$2" >/dev/null 2>&1; then echo "ok   $1 accepts: $2"; else echo "FAIL $1 should accept: $2"; naming_title_lint "$1" "$2"; fail=1; fi; }
rej() { if naming_title_lint "$1" "$2" >/dev/null 2>&1; then echo "FAIL $1 should reject: $2"; fail=1; else echo "ok   $1 rejects: $2"; fi; }

# --- effort ---
acc effort "[E545] Every verb answers a question"
acc effort "[E12] [UI] operator navigation"             # a [Flow] tag is tolerated
acc effort "[Effort] 12 · effort planning conventions"  # legacy
acc effort "[Effort] 12 · [Core] operator navigation"   # legacy with a flow tag
rej effort "Every verb answers a question"              # no prefix
rej effort "[E545.1] a sub title is not an effort"
rej effort "[E545] operator chrome — Settings ▾ dropdown"
rej effort "[E545] refactor the thing"                  # jargon
rej effort "[E545] one two three four five six seven"   # 7 words
rej effort "[E545] fix effort_new (the parser)"         # snake_case + parens
rej effort "[E545] [Growth] faster onboarding"          # flow outside the vocabulary
rej effort "[E545] "                                    # empty name

# --- sub ---
acc sub "[E545.1] One naming convention for titles"
acc sub "[Effort 12] 4 · module tables"                 # legacy
rej sub "[E545] not a sub"
rej sub "[Effort 12] 4 · Section tables — columns + joins (contract B)"
rej sub "module tables"

# --- standalone issue ---
acc issue "Start accepts the effort token"
rej issue "[E545] an effort title is not an issue"
rej issue "[Core] a tag is a prefix"
rej issue "one two three four five six seven"
rej issue "update scripts/lib/naming.sh"

# --- pull request ---
acc pr "feat(core): one naming convention [E546]"
acc pr "feat(core): one naming convention for titles [E546.1]"
acc pr "fix(start): plant no empty lockfile [#255]"
acc pr "chore(tasks): add 3 tasks [share-20261124101500]"   # the task share exception
rej pr "feat(core): no token at all"
rej pr "feat(core): token in the middle [#12] then words"
rej pr "One naming convention [E546]"                         # not conventional
rej pr "feat: parenthesis is the PR slot (E546)"
rej pr "chore(tasks): add 3 tasks [share-abc]"
if KIT_PR_TITLE_STYLE=issue-title naming_title_lint pr "[Tech Lead] [#115] adoption hardening" 2>/dev/null; then
  echo "ok   pr under issue-title style is not held to the conventional form"
else echo "FAIL pr under issue-title style"; fail=1; fi
naming_title_lint bogus "x" 2>/dev/null; t "an unknown kind is a usage error" "$?" "2"
naming_title_lint pr "" 2>/dev/null; t "an empty title is a usage error" "$?" "2"
_err="$(naming_title_lint effort "[E1] refactor one two three four five six" 2>&1 >/dev/null)"
case "$_err" in *"jargon word 'refactor'"*"7 words"*) echo "ok   every failed rule is named on stderr" ;;
  *) echo "FAIL reasons on stderr: $_err"; fail=1 ;; esac

# --- composers ---
t "effort title"          "$(naming_effort_title 545 'Every verb answers a question')" "[E545] Every verb answers a question"
t "sub title"             "$(naming_sub_title 545 2 'Start takes a token')"           "[E545.2] Start takes a token"
t "a #-prefixed number"   "$(naming_effort_title '#7' x)"                              "[E7] x"

# --- token parse ---
t "parse E545"            "$(naming_token_parse E545)"      "545"
t "parse E545.1"          "$(naming_token_parse E545.1)"    "545 1"
t "parse [e12.3]"         "$(naming_token_parse '[e12.3]')" "12 3"
naming_token_parse 545 >/dev/null;    t "a bare number is not a token" "$?" "1"
naming_token_parse E545.x >/dev/null; t "E545.x is not a token"        "$?" "1"

# --- token read from a title ---
t "token of a new effort"   "$(naming_title_token '[E545] name')"                 "E545"
t "token of a new sub"      "$(naming_title_token '[E545.3] name')"               "E545.3"
t "token of a legacy effort" "$(naming_title_token '[Effort] 545 · [Core] name')" "E545"
t "token of a legacy sub"   "$(naming_title_token '[Effort 545] 3 · name')"       "E545.3"
naming_title_token 'plain issue' >/dev/null; t "a plain title has no token" "$?" "1"
t "parent of a new sub"     "$(naming_title_parent '[E318.3] resolve profiles')"     "318"
t "parent of a legacy sub"  "$(naming_title_parent '[Effort 318] 3 · resolve')"      "318"
naming_title_parent '[E318] umbrella' >/dev/null; t "an effort title has no parent" "$?" "1"

# --- prefix strip, new and legacy ---
t "strip new effort"        "$(naming_strip_prefix '[E545] Every verb answers')"          "Every verb answers"
t "strip new sub"           "$(naming_strip_prefix '[E545.1] One naming convention')"     "One naming convention"
t "strip new + flow tag"    "$(naming_strip_prefix '[E545] [Core] tagged name')"          "tagged name"
t "strip legacy effort"     "$(naming_strip_prefix '[Effort] 86 · [Core] Plan future work')" "Plan future work"
t "strip legacy sub"        "$(naming_strip_prefix '[Effort 182] 1 · Enforce it')"         "Enforce it"
t "strip the placeholder"   "$(naming_strip_prefix '[Effort] · demo effort')"              "demo effort"
t "a plain title is kept"   "$(naming_strip_prefix 'plain issue title')"                   "plain issue title"

# --- the wrappers in effort.sh keep legacy titles valid ---
(
  # shellcheck source=/dev/null
  . "$LIB/effort.sh" >/dev/null 2>&1
  r=0
  effort_title_lint "[Effort] 12 · [UI] operator navigation" 2>/dev/null || { echo "FAIL legacy parent via effort_title_lint"; r=1; }
  effort_title_lint "[Effort 12] 4 · module tables" 2>/dev/null           || { echo "FAIL legacy sub via effort_title_lint"; r=1; }
  effort_title_lint "[E12] operator navigation" 2>/dev/null               || { echo "FAIL new parent via effort_title_lint"; r=1; }
  effort_title_lint "[E12.4] module tables" 2>/dev/null                   || { echo "FAIL new sub via effort_title_lint"; r=1; }
  effort_title_lint "[E12] refactor the wiring" 2>/dev/null               && { echo "FAIL jargon passed effort_title_lint"; r=1; }
  effort_pr_title_check "feat(core): x [E546]" 546 2>/dev/null             || { echo "FAIL check refuses [E546]"; r=1; }
  effort_pr_title_check "feat(core): x [#546]" 546 2>/dev/null             || { echo "FAIL check refuses [#546]"; r=1; }
  effort_pr_title_check "feat(core): x [E5]" 546 2>/dev/null               && { echo "FAIL check accepts the wrong effort"; r=1; }
  effort_pr_title_check "feat(core): x [E5]" 2>/dev/null                   || { echo "FAIL check without a number refuses [E5]"; r=1; }
  [ "$r" = 0 ] && echo "ok   effort_title_lint + effort_pr_title_check accept both forms"
  exit "$r"
) || fail=1

exit "$fail"
