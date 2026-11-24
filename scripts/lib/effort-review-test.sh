#!/usr/bin/env bash
# shellcheck shell=bash
# effort-review-test.sh — `cckit effort review` (scripts/lib/effort-review.sh, #583): the verdict
# table, over the forge shim and a throwaway repo with an effort branch. Hermetic, no network.
# errors: strict — a test runner: rc 1 on any failed assertion
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/scripts/lib/test-env.sh" && test_env_seal
LIB="$ROOT/scripts/lib"
fail=0
t()  { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
has() { case "$2" in *"$3"*) echo "ok: $1" ;; *) echo "FAIL: $1 -> lacks '$3' in: $2"; fail=1 ;; esac; }
command -v jq >/dev/null 2>&1 || { echo "effort-review-test: jq required" >&2; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export GH_LOG="$tmp/gh.log"; : > "$GH_LOG"
stub="$tmp/bin"
# shellcheck source=/dev/null
. "$LIB/test-forge-shim.sh"; forge_shim_install "$stub"
export PATH="$stub:$PATH" GH_TOKEN=test-token CCKIT_FORGE=github KIT_REPO=o/r
export GH_FIXTURE="$tmp/fixture.sh"
cat > "$GH_FIXTURE" <<'SH'
case "$method $ep" in
  "GET repos/o/r/issues/7/sub_issues") out="${SUBS_JSON:-[]}" ;;
  "GET repos/o/r/issues/8/sub_issues") out='[]' ;;
esac
SH
# shellcheck source=/dev/null
. "$LIB/effort-review.sh"

# ── the verdict, pure ─────────────────────────────────────────────────────────────────────────
t "closed + spec + landed is done"         "$(effort_review_verdict closed ok yes)" "done"
t "closed + spec, no branch to check"      "$(effort_review_verdict closed ok -)"   "done"
t "closed but not on the branch"           "$(effort_review_verdict closed ok no)"  "closed, not on the branch"
t "landed, issue still open"               "$(effort_review_verdict open ok yes)"   "landed, still open"
t "open"                                   "$(effort_review_verdict open ok no)"    "open"
t "no spec wins over a closed state"       "$(effort_review_verdict closed none yes)" "no spec"

# ── a repo with the effort branch: #11 and #12 have commits, #13 does not ─────────────────────
repo="$tmp/repo"; mkdir -p "$repo"
git -C "$repo" init -q -b main
git -C "$repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "base"
git -C "$repo" checkout -q -b effort/7-the-thing
git -C "$repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "feat: one [E7.1]

Closes #11"
git -C "$repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "feat: two (#12)"
git -C "$repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "chore: mentions #130 only"
git -C "$repo" checkout -q main

spec='## Spec\n- the thing works'
SUBS_JSON="$(jq -cn --arg s "$(printf "$spec")" '[
  {number: 11, state: "closed", title: "One",   body: $s},
  {number: 12, state: "open",   title: "Two",   body: $s},
  {number: 13, state: "closed", title: "Three", body: $s},
  {number: 14, state: "open",   title: "Four",  body: "## Spec\n- TODO"}
]')"
export SUBS_JSON
: > "$GH_LOG"
out="$(cd "$repo" && effort_review 7 2>&1)"; rc=$?
t   "a sub not done is rc 1"            "$rc" "1"
has "the table header"                  "$out" "$(printf 'sub\tstate\tspec\tlanded\tverdict\ttitle')"
has "#11 is done"                       "$out" "$(printf '#11\tclosed\tok\tyes\tdone\tOne')"
has "#12 landed but open"               "$out" "$(printf '#12\topen\tok\tyes\tlanded, still open\tTwo')"
has "#13 is not matched by #130"        "$out" "$(printf '#13\tclosed\tok\tno\tclosed, not on the branch\tThree')"
has "#14 has only a placeholder Spec"   "$out" "$(printf '#14\topen\tnone\tno\tno spec\tFour')"
has "the summary names the branch"      "$out" "review #7: 1 of 4 done (branch effort/7-the-thing)"
t   "one read, no writes"               "$(grep -c . "$GH_LOG")" "1"
t   "the read is the sub-issues list"   "$(grep -c '^GET repos/o/r/issues/7/sub_issues' "$GH_LOG")" "1"

SUBS_JSON="$(jq -cn --arg s "$(printf "$spec")" '[{number: 11, state: "closed", title: "One", body: $s}]')"
out="$(cd "$repo" && effort_review 7 2>&1)"; rc=$?
t   "every sub done is rc 0"            "$rc" "0"
has "all done summary"                  "$out" "review #7: 1 of 1 done"

out="$(cd "$repo" && effort_review 7 --branch main 2>&1)"; rc=$?
has "--branch picks the branch"         "$out" "$(printf '#11\tclosed\tok\tno\tclosed, not on the branch')"
out="$(cd "$repo" && effort_review 7 --branch nope 2>&1)"; rc=$?
t   "an unreadable branch is rc 1"      "$rc" "1"

out="$(cd "$tmp" && effort_review 7 2>&1)"; rc=$?
has "no branch: landed is unknown"      "$out" "$(printf '#11\tclosed\tok\t-\tdone')"

out="$(cd "$repo" && effort_review 8 2>&1)"; rc=$?
t   "no subs is rc 1"                   "$rc" "1"
has "no subs says so"                   "$out" "#8 has no sub-issues"

# ── usage ─────────────────────────────────────────────────────────────────────────────────────
: > "$GH_LOG"
effort_review >/dev/null 2>&1;            t "no effort is rc 2"        "$?" "2"
effort_review abc >/dev/null 2>&1;        t "a non-number is rc 2"     "$?" "2"
effort_review 7 8 >/dev/null 2>&1;        t "two efforts is rc 2"      "$?" "2"
effort_review 7 --bogus >/dev/null 2>&1;  t "an unknown flag is rc 2"  "$?" "2"
t "usage errors read nothing" "$(grep -c . "$GH_LOG")" "0"

out="$(CCKIT_FORGE=none; export CCKIT_FORGE; unset _FORGE_LOADED; effort_review 7 2>&1)"; rc=$?
t   "no forge: rc 1"                    "$rc" "1"
has "no forge: names the verb"          "$out" "effort review"

# ── the dispatcher routes it ──────────────────────────────────────────────────────────────────
out="$(cd "$repo" && "$ROOT/bin/cckit" effort review 2>&1)"; rc=$?
t   "cckit effort review with no N is rc 2" "$rc" "2"
has "cckit effort review prints its usage"  "$out" "usage: cckit effort review"

[ "$fail" -eq 0 ] && echo "ALL OK (effort-review)"
exit "$fail"
