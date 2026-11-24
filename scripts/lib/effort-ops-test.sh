#!/usr/bin/env bash
# shellcheck shell=bash
# effort-ops-test.sh — covers the effort lifecycle ops (#48). Hermetic: the forge shim
# (test-forge-shim.sh) answers like the REST API over a curl stand-in and logs `METHOD path {json}`;
# a throwaway git repo with a bare remote. Run:  bash scripts/lib/effort-ops-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# Sealed from the caller's KIT_*/CCKIT_*/EFFORT_* (#369): this suite builds its own fixture.
# shellcheck source=/dev/null
. "$ROOT/scripts/lib/test-env.sh" && test_env_seal
LIB="$ROOT/scripts/lib"
SCRIPTS="$ROOT/scripts"
fail=0
t()  { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
tc() { if grep -qE "$2" "$1"; then echo "ok: $3"; else echo "FAIL: $3 (no /$2/ in gh log)"; fail=1; fi; }
command -v jq  >/dev/null 2>&1 || { echo "effort-ops-test: jq required"  >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "effort-ops-test: git required" >&2; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export GH_LOG="$tmp/gh.log"; export GH_N="$tmp/n"; : > "$GH_LOG"; printf '0' > "$GH_N"

# The forge shim: a `curl` that answers like the REST API from the GH_* knobs and logs one line per
# request, plus a `gh` that fails on any subcommand (a leftover gh call is a red test). The issue
# effort_pr reads is #99 (GH_TITLE/GH_LABELS); its PR is #9 from effort/99-demo onto main.
stub="$tmp/bin"
# shellcheck source=/dev/null
. "$LIB/test-forge-shim.sh"; forge_shim_install "$stub"
export PATH="$stub:$PATH" GH_TOKEN=test-token CCKIT_FORGE=github
export GH_TITLE="[Effort] 99 · demo effort" GH_LABELS='[{"name":"role:tech-lead"},{"name":"kind:task"}]'
export GH_HEAD="effort/99-demo" GH_BASE="main" GH_MERGEABLE=true
# The parent body every GET issues/<n> answers (JSON-escaped): it carries a Spec, so effort_close
# goes past its Spec check (E546.5). The Spec cases below override it.
SPEC_BODY='## Goal\nship it\n\n## Spec\n- it ships'
export GH_BODY="$SPEC_BODY"
# What the shim does not know, answered by request (GH_FIXTURE is sourced after the shim's own case):
#   GH_DEP_PRS     the open PRs based on the effort branch (REST shape), to GET pulls?base=… (#358)
#   GH_DEP_PRS_RC  an HTTP status that makes that read fail · GH_PR_EDIT_RC=1 fails the re-target PATCH
#   the sub-issues of #77 are 301 + 302 (both closed), of #78 201 (closed) + 202 (still open) (#164)
export GH_FIXTURE="$tmp/fixture.sh"
cat > "$GH_FIXTURE" <<'SH'
case "$method $ep" in
  "GET repos/o/r/pulls")
    case "$path" in *base=*) out="${GH_DEP_PRS:-[]}"; [ "${GH_DEP_PRS_RC:-200}" = 200 ] || code="$GH_DEP_PRS_RC" ;; esac ;;
  "PATCH repos/o/r/pulls/"*) [ "${GH_PR_EDIT_RC:-0}" = 0 ] || code=422 ;;
  "GET repos/o/r/issues/77/sub_issues") out='[{"number":301,"state":"closed"},{"number":302,"state":"closed"}]' ;;
  "GET repos/o/r/issues/78/sub_issues") out='[{"number":201,"state":"closed"},{"number":202,"state":"open"}]' ;;
esac
SH
# The REST lines the lifecycle leaves in the log.
MERGE_RE='^PUT repos/o/r/pulls/[0-9]+/merge '
CLOSE_RE='^PATCH repos/o/r/issues/[0-9]+ \{"state":"closed"'
CREATE_RE='^POST repos/o/r/issues '
PR_RE='^POST repos/o/r/pulls '
no_gh() { t "$1: no gh subcommand ran" "$(grep -c '^GH-SUBCOMMAND' "$GH_LOG")" "0"; }
export KIT_REPO="o/r" EFFORT_REPO="o/r" KIT_BASE_BRANCH="main"
export KIT_WT_INSTALL=0   # #119: skip the dependency install during the hermetic worktree bootstrap
# shellcheck source=/dev/null
source "$LIB/effort.sh" 2>/dev/null
# shellcheck source=/dev/null
source "$LIB/effort-ops.sh"

# ── effort_new ────────────────────────────────────────────────────────────────────────────────
: > "$GH_LOG"
parent="$(effort_new --flow Core --spec "it ships" "demo effort" "first sub" "second sub" 2>/dev/null)"
t  "effort_new returns the parent number"          "$parent" "1"
t  "effort_new creates parent + 2 subs (3 issues)" "$(grep -cE "$CREATE_RE" "$GH_LOG")" "3"
t  "effort_new links 2 native sub-issues"          "$(grep -c '^POST repos/o/r/issues/1/sub_issues ' "$GH_LOG")" "2"
tc "$GH_LOG" '^POST repos/o/r/issues \{"title":"demo effort"' "effort_new files the parent under its name"
tc "$GH_LOG" '^PATCH repos/o/r/issues/1 \{"title":"\[E1\] demo effort"\}$' "effort_new renames the parent [E<n>] <name>, no [Flow] tag"
tc "$GH_LOG" '^POST repos/o/r/issues \{"title":"\[E1\.2\] second sub"' "effort_new titles a sub [E<n>.<step>] <name>"
# every kit-defined label is ensured (created idempotently) BEFORE the issue create uses it (#153)
tc "$GH_LOG" '^POST repos/o/r/labels \{"name":"ctx:'         "effort_new ensures the ctx:* label exists"
tc "$GH_LOG" '^POST repos/o/r/labels \{"name":"kind:task"'   "effort_new ensures the kind label exists"
tc "$GH_LOG" '^POST repos/o/r/labels \{"name":"priority:p1"' "effort_new ensures the priority label exists"
tc "$GH_LOG" '^POST repos/o/r/labels \{"name":"flow:core"'   "effort_new ensures the flow label exists"
no_gh "effort_new"
# a jargon/long name is rejected before any issue is created
: > "$GH_LOG"
effort_new "refactor the whole scripts/kit wiring layer" >/dev/null 2>&1 && rc=0 || rc=1
t  "effort_new rejects a bad title"                "$rc" "1"
t  "effort_new creates nothing on a bad title"     "$(grep -cE "$CREATE_RE" "$GH_LOG")" "0"

# ── E546.5: the ## Spec section — checked before any forge write ──────────────────────────────
: > "$GH_LOG"
err="$(effort_new "demo effort" "first sub" 2>&1 >/dev/null)" && rc=0 || rc=1
t  "effort_new refuses a body without a Spec"      "$rc" "1"
t  "effort_new writes nothing without a Spec"      "$(grep -c . "$GH_LOG")" "0"
case "$err" in *"no list item"*"--spec"*) echo "ok: the refusal gives the reason and the flag" ;; *) echo "FAIL: no-Spec refusal: $err"; fail=1 ;; esac
: > "$GH_LOG"
effort_new --spec "TBD" "demo effort" >/dev/null 2>&1 && rc=0 || rc=1
t  "effort_new refuses a placeholder-only Spec"    "$rc" "1"
t  "effort_new writes nothing on a placeholder"    "$(grep -c . "$GH_LOG")" "0"
: > "$GH_LOG"
effort_new --spec-file "$tmp/no-such-spec" "demo effort" >/dev/null 2>&1 && rc=0 || rc=1
t  "effort_new refuses an unreadable --spec-file"  "$rc" "1"
t  "effort_new writes nothing on that refusal"     "$(grep -c . "$GH_LOG")" "0"
printf '1. new refuses without it\n2. close re-checks it\n' > "$tmp/spec.md"
: > "$GH_LOG"
effort_new --spec-file "$tmp/spec.md" "demo effort" >/dev/null 2>&1 && rc=0 || rc=1
t  "effort_new takes the Spec from --spec-file"    "$rc" "0"
tc "$GH_LOG" '^POST repos/o/r/issues \{"title":"demo effort","body":"## Goal\\n[^"]*\\n\\n## Spec\\n1\. new refuses without it\\n2\. close re-checks it\\n\\n## Scope' \
   "the Spec section sits after Goal, the list kept as written"
: > "$GH_LOG"
effort_sub 99 "third step" --spec "TODO" >/dev/null 2>&1 && rc=0 || rc=1
t  "effort_sub refuses a placeholder --spec"       "$rc" "1"
t  "effort_sub writes nothing on that refusal"     "$(grep -c . "$GH_LOG")" "0"
: > "$GH_LOG"
GH_LABELS='[{"name":"effort"},{"name":"kind:task"}]' effort_sub 99 "third step" --body "one line" --spec "the step lands" >/dev/null 2>&1
tc "$GH_LOG" '^POST repos/o/r/issues \{"title":"\[E99\.3\] third step","body":"one line\\n\\n## Spec\\n- the step lands\\n\\nSub-issue of #99' \
   "effort_sub --spec adds a one-line Spec to the sub body"

# ── E547.2: the ## Grilling record — linted before any forge write, appended last ───────────────
: > "$GH_LOG"
err="$(effort_new --spec "it ships" --grilling "1. only one decision" "demo effort" 2>&1 >/dev/null)" && rc=0 || rc=1
t  "effort_new refuses a Grilling record that is not one" "$rc" "1"
t  "effort_new writes nothing on a bad Grilling record"  "$(grep -c . "$GH_LOG")" "0"
case "$err" in *"Grilled:"*"--grilling"*) echo "ok: the Grilling refusal names the missing line and the flag" ;; *) echo "FAIL: Grilling refusal: $err"; fail=1 ;; esac
printf 'Grilled: the owner, 2026-11-24, in session.\n1. a sprint is one week\n2. waves run inside it\n3. the advisor writes no code\n' > "$tmp/grill.md"
: > "$GH_LOG"
effort_new --spec "it ships" --grilling-file "$tmp/grill.md" "demo effort" >/dev/null 2>&1 && rc=0 || rc=1
t  "effort_new accepts the grill stage's record"         "$rc" "0"
tc "$GH_LOG" '^POST repos/o/r/issues \{"title":"demo effort","body":"## Goal[^"]*## Verification\\n[^"]*\\n\\n## Grilling\\n\\nGrilled: the owner, 2026-11-24, in session\.\\n1\. a sprint is one week' \
   "the Grilling section closes the body, the record kept as written"
: > "$GH_LOG"
effort_new --spec "it ships" --grilling-file "$tmp/no-such-grill" "demo effort" >/dev/null 2>&1 && rc=0 || rc=1
t  "effort_new refuses an unreadable --grilling-file"    "$rc" "1"

# ── #570: --sprint files the effort into a week's sprint ────────────────────────────────────────
: > "$GH_LOG"
effort_new --spec "it ships" --sprint=2026-11-25 "demo effort" >/dev/null 2>&1 && rc=0 || rc=1
t  "effort_new --sprint=<day> files the effort"           "$rc" "0"
tc "$GH_LOG" '^POST repos/o/r/milestones \{"title":"2026-W48"' "effort_new --sprint opens the sprint milestone"
tc "$GH_LOG" '^POST repos/o/r/issues \{"title":"demo effort","body":"[^"]*\\n\\n## Sprint\\n2026-W48 · Monday 2026-11-23 to Monday 2026-11-30"' \
   "the body names the sprint and its Monday-to-Monday bounds"
: > "$GH_LOG"
effort_new --spec "it ships" --sprint=2026-11-25 --milestone v1 "demo effort" >/dev/null 2>&1 && rc=0 || rc=1
t  "effort_new refuses --sprint with another --milestone" "$rc" "1"
t  "effort_new writes nothing on that refusal"            "$(grep -c . "$GH_LOG")" "0"

# ── effort_start / effort_pr / effort_close (real git + bare remote) ───────────────────────────
( cd "$tmp" && git init -q --bare remote.git )
( cd "$tmp" && git clone -q remote.git work \
  && cd work && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init \
  && git push -q origin HEAD:main )
cd "$tmp/work"

# #119: a gitignored local env in the root must be copied into the fresh worktree by wt_bootstrap.
printf 'SECRET=from-root\n' > "$tmp/work/.env.local"

start_out="$(effort_start 99 demo 2>/dev/null)"
t  "effort_start echoes wt|branch|num" "${start_out##*|}" "99"
t  "effort_start created the branch"   "$(git show-ref --verify --quiet refs/heads/effort/99-demo && echo yes)" "yes"
# #119: worktree dir follows the kind+N-slug convention (gc-recognizable), not the old effort-N form.
# (compare the trailing path segments — mktemp's /var may resolve to /private/var on macOS)
t  "effort_start worktree dir is effort+N-slug" \
   "$(printf '%s' "${start_out%%|*}" | sed -E 's#^.*/(\.claude/worktrees/.*)$#\1#')" \
   ".claude/worktrees/effort+99-demo"
t  "effort_start bootstrapped the worktree (.env.local copied)" \
   "$(cat "$tmp/work/.claude/worktrees/effort+99-demo/.env.local" 2>/dev/null)" "SECRET=from-root"
# #453: creating the branch stamps the effort's start; a re-start keeps the stamp it finds.
start_stamp="$(git rev-parse --git-common-dir)/effort-metrics/99.start"
t  "effort_start stamps the effort start" "$(grep -cE '^[0-9]+$' "$start_stamp" 2>/dev/null)" "1"
echo 1000000000 > "$start_stamp"
effort_start 99 demo >/dev/null 2>&1
t  "re-running effort_start keeps the start stamp" "$(cat "$start_stamp" 2>/dev/null)" "1000000000"

# move onto the effort branch (its worktree) for pr/close
cd "$tmp/work/.claude/worktrees/effort+99-demo"
: > "$GH_LOG"
effort_pr 99 --summary "SUMMARY-MARKER" --for-agents "AGENTS-MARKER" >/dev/null 2>&1
tc "$GH_LOG" '^POST repos/o/r/pulls \{"title":"[^"]*","head":"effort/99-demo","base":"main"' "effort_pr opens effort/99 → main"
# #363: parity with the kit-effort-pr skill — the verb is the one implementation.
tc "$GH_LOG" '^POST repos/o/r/pulls \{"title":"feat: demo effort \[E99\]"' "effort_pr titles with a conventional subject + the [#N] id"
# labels, milestone (M1 is milestone 3 in the shim) and the author land in ONE PATCH on the PR
tc "$GH_LOG" '^PATCH repos/o/r/issues/7 \{"labels":\["role:tech-lead","kind:task"\]' "effort_pr inherits the parent's labels"
tc "$GH_LOG" '^PATCH repos/o/r/issues/7 \{.*"milestone":3\}$' "effort_pr inherits the parent's milestone"
tc "$GH_LOG" '^POST repos/o/r/pulls \{.*SUMMARY-MARKER'       "effort_pr puts --summary in the body"
tc "$GH_LOG" '^POST repos/o/r/pulls \{.*AGENTS-MARKER'        "effort_pr puts --for-agents in the body"
tc "$GH_LOG" '^POST repos/o/r/pulls \{.*\\nCloses #99(\\n|")' "effort_pr body closes the parent"
no_gh "effort_pr"
t  "effort_pr never commits an untracked .env.local" "$(git ls-files .env.local)" ""
# #418: pr.bodyStyle = content swaps the Verification checklist for a Review one; the machine line,
# the summary and the For agents block stay.
eb="$(_eff_pr_body 99 "S-MARK" "A-MARK")"
t  "effort body (code) keeps its Verification checklist" "$(printf '%s\n' "$eb" | grep -c -e '^## Verification$' -e 'present in the diff')" "2"
eb="$(KIT_PR_BODY_STYLE=content _eff_pr_body 99 "S-MARK" "A-MARK" editor)"
t  "effort body (content) closes the parent"       "$(printf '%s\n' "$eb" | grep -c '^Closes #99$')" "1"
t  "effort body (content) keeps summary + agents"  "$(printf '%s\n' "$eb" | grep -c -e 'S-MARK' -e 'A-MARK' -e '^## For agents$')" "3"
t  "effort body (content) has a Review checklist"  "$(printf '%s\n' "$eb" | grep -c -e '^## Review$' -e 'voice matches the brand guide')" "2"
t  "effort body (content) drops the code wording"  "$(printf '%s\n' "$eb" | grep -c -e 'diff' -e 'lint/typecheck' -e '^## Verification$')" "0"
: > "$GH_LOG"
effort_pr 99 --title "feat(x): a conventional title" >/dev/null 2>&1 && rc=0 || rc=1
t  "effort_pr refuses a --title without the [#N] id" "$rc" "1"
t  "effort_pr opened nothing on a bad --title"      "$(grep -cE "$PR_RE" "$GH_LOG")" "0"
effort_pr 99 --title "feat(x): a conventional title [#99]" >/dev/null 2>&1
tc "$GH_LOG" '^POST repos/o/r/pulls \{"title":"feat\(x\): a conventional title \[#99\]"' "effort_pr honours --title"
# #237: a title the commitlint gate would reject never reaches gh — built or passed in.
: > "$GH_LOG"
effort_pr 99 --type bogus >/dev/null 2>&1 && rc=0 || rc=1
t  "effort_pr refuses a built title that fails commitlint" "$rc" "1"
t  "effort_pr opened nothing on a non-conventional built title" "$(grep -cE "$PR_RE" "$GH_LOG")" "0"
: > "$GH_LOG"
effort_pr 99 --title "[Tech Lead] [#99] demo effort" >/dev/null 2>&1 && rc=0 || rc=1
t  "effort_pr refuses a non-conventional --title"   "$rc" "1"
t  "effort_pr opened nothing on a non-conventional --title" "$(grep -cE "$PR_RE" "$GH_LOG")" "0"
: > "$GH_LOG"
effort_pr 99 --type fix >/dev/null 2>&1
tc "$GH_LOG" '^POST repos/o/r/pulls \{"title":"fix: demo effort \[E99\]"' "effort_pr --type sets the conventional type"
: > "$GH_LOG"
KIT_PR_TITLE_STYLE=issue-title effort_pr 99 >/dev/null 2>&1
tc "$GH_LOG" '^POST repos/o/r/pulls \{"title":"(\[Tech Lead\] )?\[#99\] demo effort"' "effort_pr issue-title style keeps the [#N] name form, no commitlint refusal"

# ── effort_close E546.5: the parent's Spec is re-read and checked before anything else ─────────
: > "$GH_LOG"
close_out="$(GH_BODY='## Goal\nship it' effort_close 99 2>&1)"; rc=$?
t  "effort_close refuses a parent without a Spec (rc 1)" "$rc" "1"
case "$close_out" in *"no '## Spec' section"*"--no-spec-check"*) echo "ok: the Spec refusal gives the reason and the escape" ;; *) echo "FAIL: Spec refusal message: $close_out"; fail=1 ;; esac
t  "effort_close merged nothing on a missing Spec" "$(grep -cE "$MERGE_RE" "$GH_LOG")" "0"
t  "effort_close only read the parent on a missing Spec" "$(grep -vc '^GET repos/o/r/issues/99 ' "$GH_LOG")" "0"
: > "$GH_LOG"
close_out="$(GH_BODY='## Spec\n- TODO' effort_close 99 2>&1)"; rc=$?
t  "effort_close refuses a placeholder-only Spec (rc 1)" "$rc" "1"
: > "$GH_LOG"
close_out="$(GH_FAIL_EP="repos/o/r/issues/99" effort_close 99 2>&1)"; rc=$?
t  "effort_close refuses when the body cannot be read (rc 1)" "$rc" "1"
case "$close_out" in *"could not read #99"*) echo "ok: an unread body is not a checked one" ;; *) echo "FAIL: unread-body message: $close_out"; fail=1 ;; esac
# --no-spec-check skips the check, says so in one line, and the close goes on to its next gate
# (here the trace backstop below, since the branch has no commits yet).
: > "$GH_LOG"
close_out="$(GH_BODY='## Goal\nship it' effort_close 99 --no-spec-check 2>&1)"; rc=$?
t  "effort_close --no-spec-check prints one skip notice" "$(printf '%s\n' "$close_out" | grep -c 'Spec check skipped for #99 (--no-spec-check)')" "1"
case "$close_out" in *"refusing to squash"*) echo "ok: --no-spec-check passes the Spec check" ;; *) echo "FAIL: --no-spec-check did not pass: $close_out"; fail=1 ;; esac
t  "effort_close --no-spec-check does not read the body" "$(grep -c '^GET repos/o/r/issues/99 ' "$GH_LOG")" "0"
effort_close 99 --bogus >/dev/null 2>&1; t "effort_close refuses an unknown flag (rc 2)" "$?" "2"

# ── effort_close #120: refuse-squash-without-trace backstop ────────────────────────────────────
# With NO commits on the effort branch, effort_snapshot_subs captures no trace → close must refuse
# (the squash would erase per-sub history), and must NOT merge.
: > "$GH_LOG"
close_out="$(effort_close 99 2>&1)"; rc=$?
t  "effort_close refuses without a trace (rc 1)" "$rc" "1"
case "$close_out" in *"refusing to squash"*) echo "ok: refuse message explains itself" ;; *) echo "FAIL: refuse message: $close_out"; fail=1 ;; esac
t  "effort_close did NOT merge without a trace" "$(grep -cE "$MERGE_RE" "$GH_LOG")" "0"

# ── effort_close #120: happy path — commit present → trace captured → full close ────────────────
# A real commit on the effort branch gives snapshot something to trace; close then proceeds through
# capture (pre-squash) → merge → judge/sync → close subs+parent → board Done → worktree GC →
# kit-sync drift check (#148: board Done + drift check moved into the verb from the skill).
echo "work" > file.txt
mkdir -p .claude/skills
echo "kit-managed" > .claude/skills/demo.md   # a kit-managed path → the drift check must fire (#148)
mkdir -p .claude/rules
echo "project-owned" > .claude/rules/project-owned.md   # no template of that name → must stay silent (#218)
git -c user.email=t@t -c user.name=t add file.txt .claude/skills/demo.md .claude/rules/project-owned.md
git -c user.email=t@t -c user.name=t commit -q -m "feat: do the thing (#101)"

# ── effort_close #380: effort.preCloseHook — a project gate that runs BEFORE the snapshot + merge ──
# The hook is called as `<hook> <effort#> <sub#…>` from the effort worktree. Non-zero refuses the
# close with nothing written; KIT_FORCE=1 skips it and says so. Subs 101 + 102 come from the stub.
cat > "$stub/prehook" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$PREHOOK_MARKER"
pwd -P > "$PREHOOK_MARKER.cwd"
echo "PREHOOK-SAYS: gate output"
exit "${PREHOOK_RC:-0}"
SH
chmod +x "$stub/prehook"
export PREHOOK_MARKER="$tmp/prehook.out"
# (1) a failing hook, configured through effort.preCloseHook in the config: refuse, write nothing.
printf '{"effort":{"preCloseHook":"%s"}}\n' "$stub/prehook" > "$tmp/prehook-config.json"
: > "$GH_LOG"
close_out="$(PREHOOK_RC=1 KIT_CONFIG="$tmp/prehook-config.json" effort_close 99 2>&1)"; rc=$?
t  "pre-close hook: a failing hook refuses the close (rc 1)" "$rc" "1"
case "$close_out" in *"PREHOOK-SAYS: gate output"*) echo "ok: pre-close hook: the hook's output is printed" ;; *) echo "FAIL: pre-close hook output missing: $close_out"; fail=1 ;; esac
case "$close_out" in *"pre-close hook"*"refus"*) echo "ok: pre-close hook: the refusal names the hook" ;; *) echo "FAIL: pre-close refusal message: $close_out"; fail=1 ;; esac
t  "pre-close hook: a failing hook merges nothing" "$(grep -cE "$MERGE_RE" "$GH_LOG")" "0"
t  "pre-close hook: a failing hook writes no trace" \
   "$(ls "$(git rev-parse --git-common-dir)/traces/effort-99" 2>/dev/null | grep -cE '(\.diff|\.meta|index\.jsonl)$')" "0"
# a configured hook that is missing is a gate that cannot run — refuse rather than skip it
: > "$GH_LOG"
close_out="$(KIT_EFFORT_PRE_CLOSE_HOOK="$stub/no-such-hook" effort_close 99 2>&1)"; rc=$?
t  "pre-close hook: a missing hook refuses the close (rc 1)" "$rc" "1"
t  "pre-close hook: a missing hook merges nothing" "$(grep -cE "$MERGE_RE" "$GH_LOG")" "0"
rm -f "$PREHOOK_MARKER" "$PREHOOK_MARKER.cwd"
PREHOOK_WT="$(pwd -P)"

# ── effort_close #394: a CONFLICTING PR is refused before the metrics capture writes a row ──────
: > "$GH_LOG"
close_out="$(GH_MERGEABLE=false effort_close 99 2>&1)"; rc=$?
t  "effort_close refuses a conflicting PR (rc 1)" "$rc" "1"
t  "effort_close did NOT merge a conflicting PR" "$(grep -cE "$MERGE_RE" "$GH_LOG")" "0"
case "$close_out" in
  *"metrics:"*) echo "FAIL: metrics captured before the conflict refusal"; fail=1 ;;
  *"nothing was written"*) echo "ok: conflict refused before the metrics capture" ;;
  *) echo "FAIL: conflict refusal message: $close_out"; fail=1 ;;
esac

# ── effort_close #358: open PRs based on the effort branch are re-targeted before it is deleted ──
# The selector is pure: the `{number, baseRefName}` rows read from GET pulls?base=… in, the PR
# numbers on <branch> out. DEPS_REST is the same list as the API answers it (the fixture's shape).
DEPS='[{"number":41,"baseRefName":"effort/99-demo"},{"number":42,"baseRefName":"main"},{"number":43,"baseRefName":"effort/99-demo"}]'
DEPS_REST='[{"number":41,"base":{"ref":"effort/99-demo"}},{"number":42,"base":{"ref":"main"}},{"number":43,"base":{"ref":"effort/99-demo"}}]'
t  "_eo_dependent_prs keeps only the PRs based on the branch" \
   "$(printf '%s' "$DEPS" | _eo_dependent_prs effort/99-demo | tr '\n' ' ')" "41 43 "
t  "_eo_dependent_prs: no dependents → no output" "$(printf '[]' | _eo_dependent_prs effort/99-demo)" ""
t  "_eo_dependent_prs: empty input → no output"   "$(printf '' | _eo_dependent_prs effort/99-demo)" ""
t  "_eo_dependent_prs: a prefix-sharing branch is not a match" \
   "$(printf '[{"number":9,"baseRefName":"effort/99-demo-two"}]' | _eo_dependent_prs effort/99-demo)" ""
# A failed re-target refuses the close: no merge (so no branch delete) and no metrics row.
records="$(git rev-parse --git-common-dir)/effort-metrics/records.jsonl"
rows_before="$(cat "$records" 2>/dev/null | wc -l | tr -d ' ')"
: > "$GH_LOG"
close_out="$(GH_DEP_PRS="$DEPS_REST" GH_PR_EDIT_RC=1 effort_close 99 2>&1)"; rc=$?
t  "effort_close refuses when a dependent PR cannot be re-targeted (rc 1)" "$rc" "1"
t  "effort_close did NOT merge after a failed re-target" "$(grep -cE "$MERGE_RE" "$GH_LOG")" "0"
t  "effort_close appended no metrics row on that refusal" "$(cat "$records" 2>/dev/null | wc -l | tr -d ' ')" "$rows_before"
case "$close_out" in
  *"metrics:"*) echo "FAIL: metrics captured before the re-target refusal"; fail=1 ;;
  *"PR 41"*"nothing was merged"*) echo "ok: re-target refusal names the PR" ;;
  *) echo "FAIL: re-target refusal message: $close_out"; fail=1 ;;
esac
# A failed GET pulls?base=… is not "no dependents": the close refuses instead of deleting blind.
: > "$GH_LOG"
close_out="$(GH_DEP_PRS_RC=500 effort_close 99 2>&1)"; rc=$?
t  "effort_close refuses when the dependent-PR list is unreadable (rc 1)" "$rc" "1"
t  "effort_close did NOT merge on an unreadable list" "$(grep -cE "$MERGE_RE" "$GH_LOG")" "0"

# #148: the VERB sets board Status=Done (guarded). Stub the board helpers + captured ids in-shell —
# _eo_source_board must see them and skip sourcing the real gh-project.sh.
BOARD_LOG="$tmp/board.log"; : > "$BOARD_LOG"
project_find_item_by_issue() { echo "ITEM-$1"; }
project_set_single_select()  { echo "$*" >> "$BOARD_LOG"; }
export KIT_PROJECTS_V2="true" STATUS_FIELD_ID="SF1" STATUS_OPT_DONE="OPT_DONE"

: > "$GH_LOG"
# (#380 case 2) a passing pre-close hook rides this happy path: called with effort + subs, close proceeds.
close_out="$(GH_DEP_PRS="$DEPS_REST" KIT_EFFORT_PRE_CLOSE_HOOK="$stub/prehook" effort_close 99 2>&1)"; rc=$?
export KIT_PROJECTS_V2="false"
cd "$tmp/work"   # our cwd (the effort worktree) is GC'd by the close — step to the main checkout
t  "effort_close succeeds with a trace (rc 0)" "$rc" "0"
t  "pre-close hook: called as <hook> <effort#> <sub#…>" "$(cat "$PREHOOK_MARKER" 2>/dev/null)" "99 101 102"
t  "pre-close hook: runs from the effort worktree" "$(cat "$PREHOOK_MARKER.cwd" 2>/dev/null)" "$PREHOOK_WT"
tc "$GH_LOG" '^GET repos/o/r/pulls\?head=o%3Aeffort%2F99-demo&state=open' "effort_close finds the PR for the effort branch"
tc "$GH_LOG" '^PUT repos/o/r/pulls/9/merge \{"merge_method":"squash"\}$' "effort_close squash-merges the PR"
# the remote branch goes through git, not the API — and it is gone (a cloud session keeps it, #396)
t  "effort_close deleted the remote branch" "$(git -C "$tmp/work" ls-remote --heads origin effort/99-demo | wc -l | tr -d ' ')" "0"
# #358: both dependents re-targeted to the base, and before the merge that deletes the branch
tc "$GH_LOG" '^GET repos/o/r/pulls\?base=effort%2F99-demo&state=open&per_page=100' "effort_close lists open PRs based on the effort branch"
tc "$GH_LOG" '^PATCH repos/o/r/pulls/41 \{"base":"main"\}$' "effort_close re-targets dependent PR 41 to the base"
tc "$GH_LOG" '^PATCH repos/o/r/pulls/43 \{"base":"main"\}$' "effort_close re-targets dependent PR 43 to the base"
t  "effort_close leaves a PR on another base alone" "$(grep -c '^PATCH repos/o/r/pulls/42 ' "$GH_LOG")" "0"
t  "effort_close re-targets before the merge deletes the branch" \
   "$(grep -nE 'PATCH repos/o/r/pulls/43 |PUT repos/o/r/pulls/9/merge' "$GH_LOG" | sed -E 's/^[0-9]+:(PATCH|PUT).*/\1/' | tr '\n' ' ')" "PATCH PUT "
case "$close_out" in *"PR 41 re-targeted to main"*) echo "ok: close output carries the re-targeted line" ;; *) echo "FAIL: no re-targeted line in close output"; fail=1 ;; esac
# #565: the shim's subs are already closed — close keeps their close reason (no second PATCH);
# the open-sub cases are in effort-close-subs-test.sh
t  "effort_close does not re-close an already-closed sub" "$(grep -c '^PATCH repos/o/r/issues/101 ' "$GH_LOG")" "0"
tc "$GH_LOG" '^PATCH repos/o/r/issues/99 \{"state":"closed","state_reason":"completed"\}$'  "effort_close closes the parent"
no_gh "effort_close"
case "$close_out" in *"metrics:"*) echo "ok: capture_effort_metrics composed into close" ;; *) echo "FAIL: no metrics capture in close"; fail=1 ;; esac
# #453: the row that close wrote carries a build time measured from the start stamp.
t  "effort_close records build_seconds from the start stamp" \
   "$(tail -1 "$records" | jq -r '"\(.effort) \(.build_source) \(.build_seconds | type) \(.build_seconds > 0)"')" \
   "99 effort-start number true"
# #148: board Status=Done for the parent + EVERY sub, set by the verb (was skill-only before)
tc "$BOARD_LOG" 'ITEM-99 SF1 OPT_DONE'  "effort_close sets board Done for the parent"
tc "$BOARD_LOG" 'ITEM-101 SF1 OPT_DONE' "effort_close sets board Done for sub #101"
tc "$BOARD_LOG" 'ITEM-102 SF1 OPT_DONE' "effort_close sets board Done for sub #102"
# #148: kit-sync drift check moved into the verb — a kit-managed path in the diff → advisory warning
case "$close_out" in *"kit-sync"*".claude/skills/demo.md"*) echo "ok: kit-sync drift check warns on kit-managed files" ;; *) echo "FAIL: no kit-sync warning in close output"; fail=1 ;; esac
# #218: a rule the project owns (no templates/rules/ file of that name) is never written by init or
# /kit-update, so the warning must not name it
case "$close_out" in *"project-owned.md"*) echo "FAIL: kit-sync warning names a project-owned rule"; fail=1 ;; *) echo "ok: kit-sync drift check skips a project-owned rule" ;; esac
t  "effort_close GC removed the effort worktree" \
   "$(git -C "$tmp/work" worktree list --porcelain | grep -c 'effort+99-demo')" "0"
t  "effort_close GC deleted the local branch" \
   "$(git -C "$tmp/work" show-ref --verify --quiet refs/heads/effort/99-demo && echo yes || echo no)" "no"

# ── effort_close #120: KIT_FORCE=1 override + config-gated knowledge-ingest hook ───────────────
# A second effort with no commits: close refuses by default, but KIT_FORCE=1 proceeds to merge. A
# configured knowledge-ingest hook runs post-close with the effort number (no-op when unset).
cat > "$stub/khook" <<'SH'
#!/usr/bin/env bash
printf 'ingested %s\n' "$1" > "$KHOOK_MARKER"
pwd -P > "$KHOOK_MARKER.cwd" 2>/dev/null || echo "NO-CWD" > "$KHOOK_MARKER.cwd"
[ -z "${KHOOK_SAY:-}" ] || echo "$KHOOK_SAY"
SH
chmod +x "$stub/khook"
start_out="$(effort_start 88 forced 2>/dev/null)"
cd "$tmp/work/.claude/worktrees/effort+88-forced"
: > "$GH_LOG"
# (#380 case 3) the same KIT_FORCE=1 skips a failing pre-close hook — it is never run — and says so.
rm -f "$PREHOOK_MARKER"
forced_out="$(PREHOOK_RC=1 KIT_EFFORT_PRE_CLOSE_HOOK="$stub/prehook" KHOOK_MARKER="$tmp/khook.out" KIT_EFFORT_KNOWLEDGE_HOOK="$stub/khook" KIT_FORCE=1 effort_close 88 2>&1)"
cd "$tmp/work"
case "$forced_out" in *"pre-close hook"*"skipped (KIT_FORCE=1)"*) echo "ok: pre-close hook: KIT_FORCE=1 says the hook was skipped" ;; *) echo "FAIL: no pre-close skip notice: $forced_out"; fail=1 ;; esac
t  "pre-close hook: KIT_FORCE=1 does not run the hook" "$([ -e "$PREHOOK_MARKER" ] && echo ran || echo skipped)" "skipped"
tc "$GH_LOG" '^GET repos/o/r/pulls\?head=o%3Aeffort%2F88-forced&state=open' "KIT_FORCE=1 close reads the PR of effort/88-forced"
tc "$GH_LOG" '^PUT repos/o/r/pulls/[0-9]+/merge \{"merge_method":"squash"\}$' "KIT_FORCE=1 close merges despite no trace"
t  "knowledge-ingest hook ran with the effort number" "$(cat "$tmp/khook.out" 2>/dev/null)" "ingested 88"
# #371: the close GCs the worktree it was run from; the hook must run in the main checkout, not in
# that deleted directory (where every relative path and git call fails).
t  "knowledge-ingest hook runs in the main checkout" "$(cat "$tmp/khook.out.cwd" 2>/dev/null)" "$(cd "$tmp/work" && pwd -P)"
# #148: no kit-managed file touched → the drift check stays silent
case "$forced_out" in *"kit-sync"*) echo "FAIL: kit-sync warning fired with no kit-managed change"; fail=1 ;; *) echo "ok: drift check silent when no kit-managed file changed" ;; esac

# #518: bin/cckit exports KIT_CONFIG as the config found from $PWD — the effort worktree's copy —
# and the close removes that worktree before the post-close hook is looked up. The hook named in
# the config must still run, read from the main checkout's copy.
mkdir -p "$tmp/work/.claude"
printf '{"effort":{"knowledgeIngestHook":"%s"}}\n' "$stub/khook" > "$tmp/work/.claude/kit.config.json"
effort_start 87 from-config-hook >/dev/null 2>&1
cd "$tmp/work/.claude/worktrees/effort+87-from-config-hook"
mkdir -p .claude && cp "$tmp/work/.claude/kit.config.json" .claude/kit.config.json
rm -f "$tmp/khook.out" "$tmp/khook.out.cwd"
cfg_out="$(KIT_CONFIG="$PWD/.claude/kit.config.json" KHOOK_MARKER="$tmp/khook.out" KHOOK_SAY="hook says hello" KIT_FORCE=1 effort_close 87 2>&1)"
cd "$tmp/work"
t  "post-close hook from the config runs after its worktree is gone" "$(cat "$tmp/khook.out" 2>/dev/null)" "ingested 87"
case "$cfg_out" in *"hook says hello"*) echo "ok: post-close hook output reaches the close output" ;; *) echo "FAIL: post-close hook output was discarded: $cfg_out"; fail=1 ;; esac
rm -f "$tmp/work/.claude/kit.config.json"
# With no config left anywhere, the close says the hook could not be read; it does not stay silent.
effort_start 86 config-gone >/dev/null 2>&1
cd "$tmp/work/.claude/worktrees/effort+86-config-gone"
mkdir -p .claude && printf '{"effort":{"knowledgeIngestHook":"%s"}}\n' "$stub/khook" > .claude/kit.config.json
gone_out="$(KIT_CONFIG="$PWD/.claude/kit.config.json" KHOOK_MARKER="$tmp/khook.out" KIT_FORCE=1 effort_close 86 2>&1)"
cd "$tmp/work"
case "$gone_out" in *"post-close hook not read"*) echo "ok: a config that vanished with the worktree is reported" ;; *) echo "FAIL: vanished config stayed silent: $gone_out"; fail=1 ;; esac

# ── effort_close #164: WAVE-style close — subs merged as individual task PRs, no effort branch ──
# Run from the main checkout on a non-effort branch with NO effort/<N>-* branch anywhere: the close
# must dispatch to the wave path instead of demanding the integration branch.

# refuse: a sub still open / lacking a merged PR → list the stragglers, close nothing
: > "$GH_LOG"
close_out="$(effort_close 78 2>&1)"; rc=$?
t  "wave close refuses while a sub is open (rc 1)" "$rc" "1"
case "$close_out" in *"not done"*"#202"*) echo "ok: wave refuse lists the straggler sub" ;; *) echo "FAIL: wave refuse output: $close_out"; fail=1 ;; esac
t  "wave refuse closes nothing" "$(grep -cE "$CLOSE_RE" "$GH_LOG")" "0"

# #380: the wave path has no effort worktree; the hook runs from the checkout the close was run in.
: > "$GH_LOG"; rm -f "$PREHOOK_MARKER"
close_out="$(PREHOOK_RC=1 KIT_EFFORT_PRE_CLOSE_HOOK="$stub/prehook" effort_close 77 2>&1)"; rc=$?
t  "pre-close hook: a failing hook refuses a wave close (rc 1)" "$rc" "1"
t  "pre-close hook: wave hook gets the effort + its subs" "$(cat "$PREHOOK_MARKER" 2>/dev/null)" "77 301 302"
t  "pre-close hook: a refused wave close closes nothing" "$(grep -cE "$CLOSE_RE" "$GH_LOG")" "0"

# happy: every sub CLOSED with a merged PR → trace from the PR diffs → parent closed, board Done
# for parent + subs, drift check read off the union of the merged PR diffs. The shim's diff for any
# PR is one app file (src/app.ts) and that answer cannot be changed from a fixture, so the drift
# check is asserted silent here — the kit-managed warning itself is covered on the branch path above.
: > "$BOARD_LOG"
export KIT_PROJECTS_V2="true"
: > "$GH_LOG"
close_out="$(effort_close 77 2>&1)"; rc=$?
export KIT_PROJECTS_V2="false"
t  "wave close succeeds when all subs merged (rc 0)" "$rc" "0"
# the closing PR of sub #301 is #5301 in the shim's timeline (#6301 only mentions it); its diff is
# the `GET pulls/<n>` read with the diff Accept header
tc "$GH_LOG" '^GET repos/o/r/issues/301/timeline' "wave close reads each sub's timeline for its closing PR"
tc "$GH_LOG" '^GET repos/o/r/pulls/5301 $' "wave close snapshots the merged sub PR diffs"
tc "$GH_LOG" '^PATCH repos/o/r/issues/77 \{"state":"closed","state_reason":"completed"\}$' "wave close closes the parent"
t  "wave close closes ONLY the parent (subs already closed)" "$(grep -cE "$CLOSE_RE" "$GH_LOG")" "1"
t  "wave close never squash-merges anything" "$(grep -cE "$MERGE_RE" "$GH_LOG")" "0"
tc "$BOARD_LOG" 'ITEM-77 SF1 OPT_DONE'  "wave close sets board Done for the parent"
tc "$BOARD_LOG" 'ITEM-301 SF1 OPT_DONE' "wave close sets board Done for sub #301"
tc "$BOARD_LOG" 'ITEM-302 SF1 OPT_DONE' "wave close sets board Done for sub #302"
wave_trace="$(git -C "$tmp/work" rev-parse --git-common-dir)/traces/effort-77"
t  "wave close traces the merged sub PR diffs" "$(cat "$wave_trace"/*.diff 2>/dev/null | grep -c '^diff --git a/src/app.ts ')" "2"
case "$close_out" in *"kit-sync"*) echo "FAIL: wave kit-sync warning fired with no kit-managed file in the merged diffs: $close_out"; fail=1 ;; *) echo "ok: wave drift check stays silent when the merged diffs touch no kit-managed file" ;; esac
case "$close_out" in *"project-owned.md"*) echo "FAIL: wave kit-sync warning names a project-owned rule"; fail=1 ;; *) echo "ok: wave drift check skips a project-owned rule" ;; esac
no_gh "wave close"

# ── #218 · _EO_KIT_MANAGED_RE — only the rules the kit ships are kit-managed ──────────────────────
# init.sh writes .claude/rules/<name>.md only for a templates/rules/<name>.md, so the regex lists
# those basenames instead of matching the directory. The list is hand-written; this is what fails
# when a template is added or removed without it.
_re_hit() { grep -qE "$_EO_KIT_MANAGED_RE" <<<"$1" && echo yes || echo no; }
t "a project-owned rule is not kit-managed"        "$(_re_hit .claude/rules/admin-ui-conventions.md)" "no"
t "a shipped rule is kit-managed"                  "$(_re_hit .claude/rules/effort-model.md)"         "yes"
t "a shipped rule name with a suffix is not"       "$(_re_hit .claude/rules/effort-model.md.bak)"     "no"
t "a file under a rules subdirectory is not"       "$(_re_hit .claude/rules/local/effort-model.md)"   "no"
t "skills / hooks / lib / agents stay kit-managed" \
  "$(_re_hit .claude/skills/x/SKILL.md)$(_re_hit .claude/hooks/h.sh)$(_re_hit .claude/lib/l.sh)$(_re_hit .claude/agents/a.md)$(_re_hit scripts/lib/x.sh)" "yesyesyesyesyes"
re_rules="$(printf '%s\n' "$_EO_KIT_MANAGED_RE" | sed -n 's/.*rules\/(\([^)]*\)).*/\1/p' | tr '|' '\n' | sort)"
tpl_rules="$(find "$ROOT/templates/rules" -maxdepth 1 -type f -name '*.md' -exec basename {} .md \; | sort)"
t "the regex lists exactly the templates/rules basenames" "$re_rules" "$tpl_rules"
case "$tpl_rules" in "") echo "FAIL: no templates/rules/*.md found — the sync assertion compared nothing"; fail=1 ;; esac

# ── #243 · _eff_relations_add — the ONE `Depends on` formatter (pure: no gh, no network) ──────────
rel_body="$(printf '## Verification\nV\n')"
rel1="$(_eff_relations_add "$rel_body" 5)"
t "relations_add appends a ## Relations section" "$rel1" "$(printf '## Verification\nV\n\n## Relations\n- Depends on #5')"
t "relations_add is idempotent (same line twice)" "$(_eff_relations_add "$rel1" 5)" "$rel1"
t "relations_add appends into an existing section" "$(_eff_relations_add "$rel1" 9)" \
  "$(printf '## Verification\nV\n\n## Relations\n- Depends on #5\n- Depends on #9')"
t "relations_add on an empty body has no leading blank" "$(_eff_relations_add "" 5)" \
  "$(printf '## Relations\n- Depends on #5')"
# a ## Relations section in the MIDDLE of a body keeps its place; the line lands at the section end
t "relations_add respects a mid-body section" \
  "$(_eff_relations_add "$(printf '## Relations\n- Depends on #1\n\n## Verification\nV\n')" 2)" \
  "$(printf '## Relations\n- Depends on #1\n- Depends on #2\n\n## Verification\nV')"

# ── #243 · effort_new --depends-on emits a WELL-FORMED Relations block ────────────────────────────
# It used to be built inline with `$( … )`, which eats trailing newlines — the section shipped as the
# single mangled line `## Relations- Depends on #4- Depends on #9`. Both now go through the formatter.
: > "$GH_LOG"; printf '0' > "$GH_N"
effort_new --spec "it ships" --depends-on "#4,9" "depends on effort" >/dev/null 2>&1
# the body travels as a JSON string in the POST issues line, so a line break is a literal \n there
tc "$GH_LOG" '^POST repos/o/r/issues \{.*\\n## Relations\\n'    "--depends-on writes ## Relations on its own line"
tc "$GH_LOG" '^POST repos/o/r/issues \{.*\\n- Depends on #4\\n' "--depends-on writes the first dep on its own line"
tc "$GH_LOG" '^POST repos/o/r/issues \{.*\\n- Depends on #9(\\n|")' "--depends-on writes the second dep on its own line"
t  "--depends-on does not mangle the heading" "$(grep -c '## Relations-' "$GH_LOG")" "0"

# ── #243 · effort_chain — a linear blocked_by chain, idempotent, cycle-refusing ────────────────────
# A stateful fixture for the shim — which issues exist, the blocked_by edge set, and per-issue
# bodies — so the edges and the body lines can be asserted, not just the request log. The log of
# this section is $CH_LOG (the shim writes wherever GH_LOG points).
export CH_DIR="$tmp/chain"; mkdir -p "$CH_DIR"
export CH_LOG="$CH_DIR/gh.log" CH_EDGES="$CH_DIR/edges" CH_EXISTS="$CH_DIR/exists"
printf '501\n502\n503\n504\n601\n' > "$CH_EXISTS"   # #999 deliberately absent
: > "$CH_EDGES"; : > "$CH_LOG"
for n in 501 502 503 504 601; do printf '## Goal\ng%s\n\n## Verification\nv\n' "$n" > "$CH_DIR/body.$n"; done
CHAIN_FIXTURE="$tmp/chain-fixture.sh"
cat > "$CHAIN_FIXTURE" <<'SH'
# DB id of issue N is 900000+N (the dependencies API takes the blocker's db id). Edges are "issue
# blocker" lines in $CH_EDGES; a body is $CH_DIR/body.N. CH_FAIL_EDIT=<n> makes that issue's PATCH
# fail — a POST-validation failure, the only way to reach effort_chain's rc=1 path (pre-flight
# refusals never write at all).
_n() { printf '%s' "$ep" | sed -nE 's#^repos/o/r/issues/([0-9]+).*#\1#p'; }
case "$method $ep" in
  "GET repos/o/r/issues/"*"/dependencies/blocked_by")
    out="$(awk -v k="$(_n)" 'BEGIN{printf "["} $1==k{printf "%s{\"number\":%s}", (c++?",":""), $2} END{printf "]"}' "$CH_EDGES")" ;;
  "POST repos/o/r/issues/"*"/dependencies/blocked_by")
    n="$(_n)"; bid="$(printf '%s' "$body" | jq -r .issue_id)"; b=$((bid - 900000))
    if grep -qx "$n $b" "$CH_EDGES"; then code=422; else echo "$n $b" >> "$CH_EDGES"; fi ;;   # GitHub rejects a duplicate edge
  "GET repos/o/r/issues/"*)
    n="$(_n)"
    if grep -qx "$n" "$CH_EXISTS"; then
      out="$(jq -n --argjson n "$n" --rawfile b "$CH_DIR/body.$n" '{number:$n, id:(900000+$n), title:"issue", state:"open", body:$b, labels:[]}')"
    else code=404; out='{"message":"Not Found"}'; fi ;;
  "PATCH repos/o/r/issues/"*)
    n="$(_n)"
    if [ "${CH_FAIL_EDIT:-}" = "$n" ]; then code=500
    else printf '%s' "$body" | jq -r '.body // empty' > "$CH_DIR/body.$n"; fi ;;
esac
SH
export GH_FIXTURE="$CHAIN_FIXTURE" GH_LOG="$CH_LOG"
POST_DEP_RE='^POST repos/o/r/issues/[0-9]+/dependencies/blocked_by '
EDIT_RE='^PATCH repos/o/r/issues/'
edges() { sort "$CH_EDGES" | tr '\n' ';'; }

# happy path: 502 blocked_by 501, 503 blocked_by 502, each body records its predecessor
: > "$CH_LOG"
effort_chain 501 502 503 >/dev/null 2>&1; rc=$?
t "chain happy path returns 0"              "$rc" "0"
t "chain sets both blocked_by edges"        "$(edges)" "502 501;503 502;"
tc "$CH_DIR/body.502" '^- Depends on #501$' "chain records 'Depends on #501' in #502"
tc "$CH_DIR/body.503" '^- Depends on #502$' "chain records 'Depends on #502' in #503"
tc "$CH_DIR/body.502" '^## Relations$'       "chain adds a ## Relations section"
t "chain leaves the head issue's body alone" "$(grep -c 'Depends on' "$CH_DIR/body.501")" "0"

# idempotency: a second identical run writes NOTHING — no POST, no body edit, no duplicate line
: > "$CH_LOG"
effort_chain 501 502 503 >/dev/null 2>&1; rc=$?
t "chain re-run returns 0"                   "$rc" "0"
t "chain re-run sets no new edge"            "$(edges)" "502 501;503 502;"
t "chain re-run POSTs no dependency"         "$(grep -cE "$POST_DEP_RE" "$CH_LOG")" "0"
t "chain re-run edits no body"               "$(grep -cE "$EDIT_RE" "$CH_LOG")" "0"
t "chain re-run leaves ONE Depends on line"  "$(grep -c 'Depends on #501' "$CH_DIR/body.502")" "1"
# a `#`-prefixed number is the same issue
: > "$CH_LOG"
effort_chain '#501' '#502' >/dev/null 2>&1
t "chain accepts #-prefixed numbers"         "$(grep -cE "$POST_DEP_RE" "$CH_LOG")" "0"

# arity: fewer than two numbers is a usage error and writes nothing
: > "$CH_LOG"
effort_chain 501 >/dev/null 2>&1 && rc=0 || rc=1
t "chain refuses a single issue (rc 1)"      "$rc" "1"
effort_chain >/dev/null 2>&1 && rc=0 || rc=1
t "chain refuses zero issues (rc 1)"         "$rc" "1"
t "chain arity refusal writes nothing"       "$(grep -cE "$POST_DEP_RE|$EDIT_RE" "$CH_LOG")" "0"

# a non-numeric argument is rejected up front
: > "$CH_LOG"
effort_chain 501 not-a-number >/dev/null 2>&1 && rc=0 || rc=1
t "chain refuses a non-numeric arg (rc 1)"   "$rc" "1"
t "chain non-numeric refusal writes nothing" "$(grep -cE "$POST_DEP_RE|$EDIT_RE" "$CH_LOG")" "0"

# a nonexistent issue aborts the WHOLE chain — the earlier, valid link is not written either
: > "$CH_LOG"
effort_chain 504 999 >/dev/null 2>&1 && rc=0 || rc=1
t "chain refuses a nonexistent issue (rc 1)" "$rc" "1"
t "chain missing-issue refusal writes nothing" "$(grep -cE "$POST_DEP_RE|$EDIT_RE" "$CH_LOG")" "0"
t "chain missing-issue refusal adds no edge" "$(edges)" "502 501;503 502;"

# a repeated number is a cycle (`chain 1 2 1`) — refused whole
: > "$CH_LOG"
effort_chain 504 501 504 >/dev/null 2>&1 && rc=0 || rc=1
t "chain refuses a repeated number (rc 1)"   "$rc" "1"
t "chain repeat refusal writes nothing"      "$(grep -cE "$POST_DEP_RE|$EDIT_RE" "$CH_LOG")" "0"

# a cycle through edges GitHub ALREADY holds: 503 → 502 → 501 exists, so 501 blocked_by 503 loops
: > "$CH_LOG"
effort_chain 503 501 >/dev/null 2>&1 && rc=0 || rc=1
t "chain refuses a transitive cycle (rc 1)"  "$rc" "1"
t "chain cycle refusal writes nothing"       "$(grep -cE "$POST_DEP_RE|$EDIT_RE" "$CH_LOG")" "0"
t "chain cycle refusal adds no edge"         "$(edges)" "502 501;503 502;"

# an issue already blocked by something ELSE keeps that blocker — chain only ever ADDS its edge
echo "504 601" >> "$CH_EDGES"
: > "$CH_LOG"
effort_chain 501 504 >/dev/null 2>&1; rc=$?
t "chain wires an already-blocked issue (rc 0)" "$rc" "0"
t "chain preserves the pre-existing blocker"    "$(edges)" "502 501;503 502;504 501;504 601;"
tc "$CH_DIR/body.504" '^- Depends on #501$'     "chain records its own dep on an already-blocked issue"

# The summary banner must agree with rc. A ✓ over a nonzero exit reports a chain that is not fully
# wired, so the failure is invisible to anything reading stderr rather than $?.
: > "$CH_LOG"
out="$(effort_chain 501 502 2>&1)"; rc=$?
t "chain banner: rc 0 on a clean run"        "$rc" "0"
case "$out" in *"✓ chain"*) t "chain banner: ✓ on success" ok ok ;; *) t "chain banner: ✓ on success" "$out" "✓ chain" ;; esac

# A POST-validation failure: #601 exists and passes pre-flight, but its body edit fails. This is the
# only path that reaches rc=1 with writes already attempted — every pre-flight refusal returns early.
: > "$CH_LOG"
out="$(CH_FAIL_EDIT=601 effort_chain 502 601 2>&1)"; rc=$?
t "chain returns rc 1 when a body edit fails" "$rc" "1"
case "$out" in
  *"✓ chain"*) t "chain banner: no ✓ when a link failed" "$out" "(no '✓ chain')" ;;
  *"✗ chain"*) t "chain banner: ✗ when a link failed"    "ok" "ok" ;;
  *)           t "chain banner: ✗ when a link failed"    "$out" "✗ chain" ;;
esac

# ── #244 · effort_start enforces a WIP limit ──────────────────────────────────────────────────────
# In progress = an `effort/<N>-<slug>` ref exists (local head OR remote-tracking) — the same scan the
# slug resolver uses. Its own throwaway repo + bare remote so the branch inventory is exactly what
# each case sets up, and its own gh log so "a refusal writes NOTHING" can be asserted against zero
# gh calls as well as zero refs.
wtmp="$tmp/wip"; mkdir -p "$wtmp"
( cd "$wtmp" && git init -q --bare remote.git )
( cd "$wtmp" && git clone -q remote.git work \
  && cd work && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init \
  && git push -q origin HEAD:main )
cd "$wtmp/work" || exit 1
unset EFFORT_WIP_LIMIT KIT_EFFORT_WIP_LIMIT KIT_FORCE 2>/dev/null || true
# The shim logs to $CH_LOG here (GH_LOG points at it since the chain section) — that is the log a
# refusal must leave empty. The chain fixture stays installed: the title read of an issue it does not
# know is a 404, which effort_start survives (#330), and every start below names its slug anyway.

wip_started() { git show-ref --verify --quiet "refs/heads/effort/$1" && echo yes || echo no; }
wip_reset() { git checkout -q main 2>/dev/null; \
  for b in $(git for-each-ref --format='%(refname:short)' 'refs/heads/effort/*'); do
    git worktree remove --force ".claude/worktrees/effort+${b#effort/}" >/dev/null 2>&1
    git branch -D "$b" >/dev/null 2>&1
  done; git worktree prune >/dev/null 2>&1; }

# 1. under the limit → starts. Nothing in progress, default limit 2.
effort_start 701 one >/dev/null 2>&1; rc=$?
t "wip: under the limit starts (rc 0)"  "$rc" "0"
t "wip: under the limit created the branch" "$(wip_started 701-one)" "yes"

# 2. the SECOND effort still starts (1 < 2) — the limit is a ceiling, not a one-at-a-time rule.
effort_start 702 two >/dev/null 2>&1; rc=$?
t "wip: the second effort starts (rc 0)" "$rc" "0"

# 3. AT the limit (2 in progress, limit 2) → refuse. A third would make three.
: > "$CH_LOG"
out="$(effort_start 703 three 2>&1)"; rc=$?
t "wip: at the limit refuses (rc 1)" "$rc" "1"
case "$out" in *"WIP limit is 2"*) echo "ok: refusal names the limit" ;; *) echo "FAIL: refusal did not name the limit: $out"; fail=1 ;; esac
case "$out" in *"one #701"*) echo "ok: refusal lists what is in progress" ;; *) echo "FAIL: refusal did not list #701: $out"; fail=1 ;; esac
case "$out" in *"--force"*) echo "ok: refusal says how to override" ;; *) echo "FAIL: refusal did not mention --force: $out"; fail=1 ;; esac
case "$out" in *"effort.wipLimit"*) echo "ok: refusal names the config key" ;; *) echo "FAIL: refusal did not name effort.wipLimit: $out"; fail=1 ;; esac
# …and the refusal WRITES nothing: no branch, no worktree dir, no board change.
t "wip: refusal created no branch"   "$(wip_started 703-three)" "no"
t "wip: refusal created no worktree" "$(ls -d .claude/worktrees/effort+703-three 2>/dev/null | wc -l | tr -d ' ')" "0"
# For a NUMERIC argument the refusal also makes no forge call — the number is passed through, so no
# resolution happens. This is NOT the guarantee for a <slug> argument (see the next assertion), and
# the docs claim only "no branch, no worktree, no board change" (#244 review).
t "wip: a numeric-arg refusal made no forge call" "$(grep -c . "$CH_LOG" | tr -d ' ')" "0"
# A SLUG argument is resolved BEFORE the gate, and the resolver falls through to the issue list
# (the slug: label, then the open effort titles) when no branch matches — so a refusal on that path
# can read from GitHub. Asserted on the resolver
# itself, which is the mechanism the narrowed doc claim refers to.
: > "$CH_LOG"
effort_slug_resolve no-such-effort-anywhere >/dev/null 2>&1 || true
t "wip: resolving a slug with no branch DOES read the forge" \
  "$(grep -cE '^GET repos/o/r/issues\?' "$CH_LOG" | tr -d ' ')" "2"

# 4. --force starts anyway (and says so).
out="$(effort_start --force 703 three 2>&1)"; rc=$?
t "wip: --force starts anyway (rc 0)" "$rc" "0"
t "wip: --force created the branch"   "$(wip_started 703-three)" "yes"
case "$out" in *"anyway"*) echo "ok: --force announces the override" ;; *) echo "FAIL: --force said nothing: $out"; fail=1 ;; esac

# 5. ABOVE the limit (3 in progress, limit 2) still refuses.
effort_start 704 four >/dev/null 2>&1; rc=$?
t "wip: above the limit refuses (rc 1)" "$rc" "1"
t "wip: above the limit created no branch" "$(wip_started 704-four)" "no"

# 6. KIT_FORCE=1 — the same escape hatch effort_close uses — starts anyway.
KIT_FORCE=1 effort_start 704 four >/dev/null 2>&1; rc=$?
t "wip: KIT_FORCE=1 starts anyway (rc 0)" "$rc" "0"
t "wip: KIT_FORCE=1 created the branch"   "$(wip_started 704-four)" "yes"

# 7. re-running start on an ALREADY in-progress effort is never gated — it adds no WIP, so
#    `effort start` stays safe to re-run even when the set is at or over the limit.
out="$(effort_start 701 one 2>&1)"; rc=$?
t "wip: re-starting an in-progress effort is allowed (rc 0)" "$rc" "0"
case "$out" in *"WIP limit"*) echo "FAIL: re-start hit the WIP gate: $out"; fail=1 ;; *) echo "ok: re-start bypasses the gate" ;; esac

# 8. a REMOTE-only effort branch counts as in progress (another machine owns it).
wip_reset
git push -q origin main:refs/heads/effort/705-remote-only
git fetch -q origin
t "wip: only a remote effort ref is present" "$(effort_wip_rows | tr '\t' '-' | tr '\n' ' ')" "705-remote-only "
EFFORT_WIP_LIMIT=1 effort_start 706 local-one >/dev/null 2>&1; rc=$?
t "wip: a remote-only effort branch counts toward the limit (rc 1)" "$rc" "1"
git push -q origin :refs/heads/effort/705-remote-only; git fetch -q --prune origin

# ── #244 review · the cached refs/remotes is wrong in BOTH directions ─────────────────────────────
# effort_wip_rows reads origin with `git ls-remote`, not refs/remotes, because the cache under- and
# over-counts and a gate is wrong with either. Both directions are reproduced here against the real
# bare remote, with the local cache deliberately left un-fetched / un-pruned.

# 8a. OVER-count: a branch DELETED on origin lingers in refs/remotes until a prune. The stale ref
#     must not block a start. The delete is written into the bare remote rather than pushed from
#     here as `origin :ref` — a delete-push updates THIS clone's tracking ref, which would hide the
#     staleness under test. Writing the remote is the "another machine deleted it" case.
wip_reset
git push -q origin main:refs/heads/effort/720-stale
git fetch -q origin                                   # cache it
git --git-dir="$wtmp/remote.git" update-ref -d refs/heads/effort/720-stale
t "wip: the deleted branch is still in the local cache" \
  "$(git for-each-ref --format='%(refname:short)' refs/remotes 2>/dev/null | grep -c 'effort/720-stale' | tr -d ' ')" "1"
t "wip: a stale remote-tracking ref is NOT counted" \
  "$(effort_wip_rows | grep -c '^720' | tr -d ' ')" "0"
EFFORT_WIP_LIMIT=1 effort_start 721 not-blocked >/dev/null 2>&1; rc=$?
t "wip: a stale ref does not block a start (rc 0)" "$rc" "0"
t "wip: the unblocked start created its branch"    "$(wip_started 721-not-blocked)" "yes"
git fetch -q --prune origin

# 8b. UNDER-count: a branch pushed to origin since the last fetch is absent from refs/remotes — and
#     effort_start's own fetch is base-only, so it would never appear. It must still be counted.
#     `git update-ref` inside the bare remote is the "another machine pushed" case with no fetch.
wip_reset
git --git-dir="$wtmp/remote.git" update-ref refs/heads/effort/722-unfetched \
  "$(git rev-parse origin/main)"
t "wip: the new branch is absent from the local cache" \
  "$(git for-each-ref --format='%(refname:short)' refs/remotes 2>/dev/null | grep -c 'effort/722-unfetched' | tr -d ' ')" "0"
t "wip: an unfetched origin branch IS counted" \
  "$(effort_wip_rows | grep -c '^722' | tr -d ' ')" "1"
out="$(EFFORT_WIP_LIMIT=1 effort_start 723 blocked-by-unfetched 2>&1)"; rc=$?
t "wip: an unfetched origin branch blocks a start (rc 1)" "$rc" "1"
t "wip: that refusal created no branch" "$(wip_started 723-blocked-by-unfetched)" "no"
case "$out" in *"722"*) echo "ok: the refusal names the unfetched effort" ;; *) echo "FAIL: refusal did not name #722: $out"; fail=1 ;; esac

# 8c. EFFORT_WIP_REMOTE=0 opts out of the origin query and counts the cache — so with the same
#     un-fetched origin branch the count goes back to the old approximation (absent), which is
#     exactly what "deterministic offline mode" means.
t "wip: EFFORT_WIP_REMOTE=0 skips the origin query" \
  "$(EFFORT_WIP_REMOTE=0 effort_wip_rows | grep -c '^722' | tr -d ' ')" "0"
EFFORT_WIP_REMOTE=0 EFFORT_WIP_LIMIT=1 effort_start 724 optout >/dev/null 2>&1; rc=$?
t "wip: EFFORT_WIP_REMOTE=0 starts under the cached count (rc 0)" "$rc" "0"
wip_reset
git --git-dir="$wtmp/remote.git" update-ref -d refs/heads/effort/722-unfetched

# 8d. an UNREACHABLE origin must not fail the start: the count falls back to the cached refs, warns
#     once on stderr, and the gate proceeds. A gate that hard-fails offline is worse than one that
#     miscounts.
wip_reset
git remote set-url origin "$wtmp/nope-does-not-exist.git"
rows_out="$(effort_wip_rows 2>&1 >/dev/null)"
case "$rows_out" in *"may be stale"*) echo "ok: an unreachable origin warns" ;; *) echo "FAIL: no staleness warning: $rows_out"; fail=1 ;; esac
out="$(effort_start 725 offline 2>&1)"; rc=$?
t "wip: an unreachable origin still starts the effort (rc 0)" "$rc" "0"
t "wip: the offline start created its branch" "$(wip_started 725-offline)" "yes"
git remote set-url origin "$wtmp/remote.git"
wip_reset

# 9. limit 0 freezes new efforts entirely (nothing in progress, and still a refusal).
wip_reset
EFFORT_WIP_LIMIT=0 effort_start 707 frozen >/dev/null 2>&1; rc=$?
t "wip: limit 0 refuses with nothing in progress (rc 1)" "$rc" "1"
t "wip: limit 0 created no branch" "$(wip_started 707-frozen)" "no"
EFFORT_WIP_LIMIT=0 effort_start --force 707 frozen >/dev/null 2>&1; rc=$?
t "wip: limit 0 is still overridable (rc 0)" "$rc" "0"

# 10. a misconfigured limit is IGNORED with a warning and the built-in default (2) is used —
#     a typo must neither disable the gate nor wedge the verb.
wip_reset
out="$(EFFORT_WIP_LIMIT=lots effort_start 708 typo 2>&1)"; rc=$?
t "wip: a non-numeric limit still starts under the default (rc 0)" "$rc" "0"
case "$out" in *"must be a non-negative integer"*) echo "ok: a bad limit warns" ;; *) echo "FAIL: no warning for a bad limit: $out"; fail=1 ;; esac
out="$(EFFORT_WIP_LIMIT=-1 effort_start 709 negative 2>&1)"; rc=$?
t "wip: a negative limit falls back to the default too (rc 0)" "$rc" "0"
# two are now in progress under the fallback default of 2 → the next one is refused
EFFORT_WIP_LIMIT=lots effort_start 710 third >/dev/null 2>&1; rc=$?
t "wip: the fallback default is really 2 (rc 1)" "$rc" "1"

# 11. the limit is read from `effort.wipLimit` in the project config when no env var is set…
wip_reset
mkdir -p .claude
printf '{"effort":{"wipLimit":1}}\n' > .claude/kit.config.json
effort_start 711 from-config >/dev/null 2>&1
out="$(effort_start 712 from-config-two 2>&1)"; rc=$?
t "wip: effort.wipLimit=1 refuses the second effort (rc 1)" "$rc" "1"
case "$out" in *"WIP limit is 1"*) echo "ok: the configured limit is the one enforced" ;; *) echo "FAIL: config limit not used: $out"; fail=1 ;; esac
# …and EFFORT_WIP_LIMIT wins over it, per invocation.
EFFORT_WIP_LIMIT=3 effort_start 712 from-config-two >/dev/null 2>&1; rc=$?
t "wip: EFFORT_WIP_LIMIT overrides the config (rc 0)" "$rc" "0"
# KIT_EFFORT_WIP_LIMIT (what load_kit_config exports) is read when EFFORT_WIP_LIMIT is unset.
wip_reset
out="$(KIT_EFFORT_WIP_LIMIT=0 effort_start 713 kitenv 2>&1)"; rc=$?
t "wip: KIT_EFFORT_WIP_LIMIT is honoured (rc 1)" "$rc" "1"
rm -f .claude/kit.config.json

# 12. effort_wip_rows counts each effort ONCE even when local + remote refs both carry it.
wip_reset
effort_start 714 dedup >/dev/null 2>&1
git push -q origin effort/714-dedup; git fetch -q origin
t "wip: local + remote refs count as one effort" "$(effort_wip_rows | wc -l | tr -d ' ')" "1"
git push -q origin :refs/heads/effort/714-dedup >/dev/null 2>&1; git fetch -q --prune origin
wip_reset

# 13. an unknown flag is rejected before anything happens.
: > "$CH_LOG"
effort_start --nope 715 x >/dev/null 2>&1; rc=$?
t "wip: an unknown flag is rejected (rc 1)" "$rc" "1"
t "wip: an unknown flag writes nothing"     "$(grep -c . "$CH_LOG" | tr -d ' ')" "0"

# 14. scope: the gate is an EFFORT gate. `cckit start <issue>` (wt_start, worktree-start.sh) has no
#     WIP limit — a static guard so widening the scope can't happen by accident.
t "wip: the plain-task start path is not gated" \
  "$(grep -c '_eff_wip_gate\|effort_wip_rows' "$LIB/worktree-start.sh" | tr -d ' ')" "0"

cd "$tmp/work" || exit 1

# 15. the label `effort_plan` READS is a label `effort_new` WRITES.
#     These drifted apart silently: effort-plan.sh queried `--label effort`, effort_new applied
#     ctx/kind/priority/role/flow/slug and never `effort`, and setup-labels.sh never created
#     it. `cckit effort plan` therefore answered "no open efforts found" for every effort ever
#     made, in every repo, with no error anywhere. A static check because the failure mode is
#     silence — there is nothing at runtime to notice.
plan_label="$(sed -n 's/.*forge_rest "repos\/\$repo\/issues" [^|]*-f labels=\([a-z][a-z-]*\).*/\1/p' "$LIB/effort-plan.sh" | sed -n 1p)"
t "plan queries a label at all" "${plan_label:-MISSING}" "effort"
t "effort_new applies the label plan queries" \
  "$(grep -c "labels=\"$plan_label," "$LIB/effort-ops.sh" | tr -d ' ')" "1"
t "effort_new ensures the label exists before using it" \
  "$(grep -c "_eff_ensure_label \"$plan_label\"" "$LIB/effort-ops.sh" | tr -d ' ')" "1"
t "setup-labels provisions the label plan queries" \
  "$(grep -c "ensure_label \"$plan_label\"" "$SCRIPTS/setup-labels.sh" | tr -d ' ')" "1"

# 16. #330 — a failed forge read is said, never a silent rc 1. With the issue read failing, the bare
#     `title="$(…)"` assignment ended effort_start under `set -e` with no output at all. GH_FAIL_EP
#     makes the shim answer 404 on that one endpoint.
wip_reset
out="$( set -e; GH_FAIL_EP="repos/o/r/issues/801" EFFORT_WIP_REMOTE=0 effort_start --force 801 2>&1 )"; rc=$?
t "#330: effort_start survives a failed title read (rc 0)" "$rc" "0"
case "$out" in *"could not read the title of issue #801"*) echo "ok: #330: the failed title read is named on stderr" ;;
  *) echo "FAIL: #330: no message for the failed title read -> '$out'"; fail=1 ;; esac
t "#330: the fallback slug made the branch" "$(git show-ref --verify --quiet refs/heads/effort/801-effort && echo yes)" "yes"
# A re-start during the outage lands on the effort's existing branch, not on a second one.
git branch -q effort/802-real-slug
out="$( set -e; GH_FAIL_EP="repos/o/r/issues/802" EFFORT_WIP_REMOTE=0 effort_start --force 802 2>&1 )"; rc=$?
t "#330: a re-start with the forge failing keeps rc 0" "$rc" "0"
t "#330: a re-start with the forge failing cuts no fallback branch" \
  "$(git show-ref --verify --quiet refs/heads/effort/802-effort && echo yes || echo no)" "no"
# effort_close: a failed PR read (GET pulls?head=…) refuses by name instead of dying on the bare
# assignment — and before the capture writes a records.jsonl row and consumes the start marker (the
# write-then-fail #394 exists to prevent). --no-spec-check: the chain fixture answers 404 for #801's
# body, and the read under test here is the PR's.
: > "$CH_LOG"
out="$( set -e; cd "$(git worktree list --porcelain | awk -v b=refs/heads/effort/801-effort '/^worktree /{w=$2} $2==b{print w}')" \
        && GH_FAIL_EP="repos/o/r/pulls" KIT_FORCE=1 effort_close 801 --no-spec-check 2>&1 )"; rc=$?
t "#330: effort_close refuses when the PR cannot be read (rc 1)" "$rc" "1"
case "$out" in *"could not read the PR for effort/801-effort"*) echo "ok: #330: effort_close names the failed PR read" ;;
  *) echo "FAIL: #330: effort_close gave no reason -> '$out'"; fail=1 ;; esac
t "#330: nothing was merged on the failed read" "$(grep -cE "$MERGE_RE" "$CH_LOG")" "0"
out="$( set -e; cd "$(git worktree list --porcelain | awk -v b=refs/heads/effort/801-effort '/^worktree /{w=$2} $2==b{print w}')" \
        && echo work > rest-twin.txt && git add rest-twin.txt \
        && git -c user.email=t@t -c user.name=t commit -q -m "feat: work (#801)" \
        && GH_FAIL_EP="repos/o/r/pulls" KIT_FORCE=1 effort_close 801 --no-spec-check 2>&1 )"; rc=$?
t "#330: with a trace, effort_close still refuses the failed PR read (rc 1)" "$rc" "1"
case "$out" in
  *"metrics:"*) echo "FAIL: #330: metrics captured before the failed PR read was refused -> '$out'"; fail=1 ;;
  *"could not read the PR for effort/801-effort"*"nothing was written"*) echo "ok: #330: the refusal says nothing was written" ;;
  *) echo "FAIL: #330: effort_close gave no reason -> '$out'"; fail=1 ;; esac
no_gh "the whole wip + #330 section"

[ "$fail" -eq 0 ] && echo "ALL OK (effort-ops)" || echo "effort-ops: FAILURES"
exit "$fail"
