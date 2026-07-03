#!/usr/bin/env bash
# shellcheck shell=bash
# effort-ops-test.sh — covers the effort lifecycle ops (#48). Hermetic: stubs gh (no network/auth)
# and uses a throwaway git repo with a bare remote. Run:  bash scripts/lib/effort-ops-test.sh
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$ROOT/scripts/lib"
fail=0
t()  { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
tc() { if grep -qE "$2" "$1"; then echo "ok: $3"; else echo "FAIL: $3 (no /$2/ in gh log)"; fail=1; fi; }
command -v jq  >/dev/null 2>&1 || { echo "effort-ops-test: jq required"  >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "effort-ops-test: git required" >&2; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export GH_LOG="$tmp/gh.log"; export GH_N="$tmp/n"; : > "$GH_LOG"

# Stub gh: log every call, return canned output keyed on the subcommand.
stub="$tmp/bin"; mkdir -p "$stub"
cat > "$stub/gh" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
case "$1 $2" in
  "issue create")  n=$(( $(cat "$GH_N" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$GH_N"
                   echo "https://github.com/o/r/issues/$n" ;;
  "issue edit"|"issue close"|"pr merge") exit 0 ;;
  "issue view")    echo "[Effort] 99 · demo effort" ;;          # --json title -q .title
  "pr create")     echo "https://github.com/o/r/pull/7" ;;
  "pr diff")       # a merged sub PR's diff (wave-style close, #164): one kit-managed + one app file
    printf 'diff --git a/.claude/skills/demo.md b/.claude/skills/demo.md\n+kit\ndiff --git a/src/app.ts b/src/app.ts\n+app\n' ;;
  "api "*|"api")
    case "$*" in
      *"--method POST"*"/sub_issues"*) exit 0 ;;                # link a sub
      *"/sub_issues"*".[].number"*)    printf '101\n102\n' ;;   # list subs (for close)
      # wave-style close (#164): per-sub "sub|state|pr|merge-oid|title" rows by parent number
      *closedByPullRequestsReferences*n=77*) printf '301|CLOSED|501|abc1234def|first sub\n302|CLOSED|502|bcd2345eab|second sub\n' ;;
      *closedByPullRequestsReferences*n=78*) printf '201|CLOSED|401|abc1234def|done sub\n202|OPEN|||still open sub\n' ;;
      *".id"*)                         echo "55501" ;;          # issue db id
      *) exit 0 ;;
    esac ;;
  *) exit 0 ;;
esac
SH
chmod +x "$stub/gh"
export PATH="$stub:$PATH"
export KIT_REPO="o/r" EFFORT_REPO="o/r" KIT_BASE_BRANCH="main"
export KIT_WT_INSTALL=0   # #119: skip the dependency install during the hermetic worktree bootstrap
# shellcheck source=/dev/null
source "$LIB/effort.sh" 2>/dev/null
# shellcheck source=/dev/null
source "$LIB/effort-ops.sh"

# ── effort_new ────────────────────────────────────────────────────────────────────────────────
: > "$GH_LOG"
parent="$(effort_new --flow Core "demo effort" "first sub" "second sub" 2>/dev/null)"
t  "effort_new returns the parent number"          "$parent" "1"
t  "effort_new creates parent + 2 subs (3 issues)" "$(grep -c 'issue create' "$GH_LOG")" "3"
t  "effort_new links 2 native sub-issues"          "$(grep -c 'method POST .*sub_issues' "$GH_LOG")" "2"
tc "$GH_LOG" 'issue create .*--title \[Effort\] · \[Core\] demo effort' "effort_new titles the parent"
# every kit-defined label is ensured (created idempotently) BEFORE the issue create uses it (#153)
tc "$GH_LOG" 'label create ctx:'        "effort_new ensures the ctx:* label exists"
tc "$GH_LOG" 'label create kind:task'   "effort_new ensures the kind label exists"
tc "$GH_LOG" 'label create priority:p1' "effort_new ensures the priority label exists"
tc "$GH_LOG" 'label create flow:core'   "effort_new ensures the flow label exists"
# a jargon/long name is rejected before any issue is created
: > "$GH_LOG"
effort_new "refactor the whole scripts/kit wiring layer" >/dev/null 2>&1 && rc=0 || rc=1
t  "effort_new rejects a bad title"                "$rc" "1"
t  "effort_new creates nothing on a bad title"     "$(grep -c 'issue create' "$GH_LOG")" "0"

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

# move onto the effort branch (its worktree) for pr/close
cd "$tmp/work/.claude/worktrees/effort+99-demo"
: > "$GH_LOG"
effort_pr 99 >/dev/null 2>&1
tc "$GH_LOG" 'pr create .*--base main --head effort/99-demo' "effort_pr opens effort/99 → main"

# ── effort_close #120: refuse-squash-without-trace backstop ────────────────────────────────────
# With NO commits on the effort branch, effort_snapshot_subs captures no trace → close must refuse
# (the squash would erase per-sub history), and must NOT merge.
: > "$GH_LOG"
close_out="$(effort_close 99 2>&1)"; rc=$?
t  "effort_close refuses without a trace (rc 1)" "$rc" "1"
case "$close_out" in *"refusing to squash"*) echo "ok: refuse message explains itself" ;; *) echo "FAIL: refuse message: $close_out"; fail=1 ;; esac
t  "effort_close did NOT merge without a trace" "$(grep -c 'pr merge' "$GH_LOG")" "0"

# ── effort_close #120: happy path — commit present → trace captured → full close ────────────────
# A real commit on the effort branch gives snapshot something to trace; close then proceeds through
# capture (pre-squash) → merge → judge/sync → close subs+parent → board Done → worktree GC →
# kit-sync drift check (#148: board Done + drift check moved into the verb from the skill).
echo "work" > file.txt
mkdir -p .claude/skills
echo "kit-managed" > .claude/skills/demo.md   # a kit-managed path → the drift check must fire (#148)
git -c user.email=t@t -c user.name=t add file.txt .claude/skills/demo.md
git -c user.email=t@t -c user.name=t commit -q -m "feat: do the thing (#101)"

# #148: the VERB sets board Status=Done (guarded). Stub the board helpers + captured ids in-shell —
# _eo_source_board must see them and skip sourcing the real gh-project.sh.
BOARD_LOG="$tmp/board.log"; : > "$BOARD_LOG"
project_find_item_by_issue() { echo "ITEM-$1"; }
project_set_single_select()  { echo "$*" >> "$BOARD_LOG"; }
export KIT_PROJECTS_V2="true" STATUS_FIELD_ID="SF1" STATUS_OPT_DONE="OPT_DONE"

: > "$GH_LOG"
close_out="$(effort_close 99 2>&1)"; rc=$?
export KIT_PROJECTS_V2="false"
cd "$tmp/work"   # our cwd (the effort worktree) is GC'd by the close — step to the main checkout
t  "effort_close succeeds with a trace (rc 0)" "$rc" "0"
tc "$GH_LOG" 'pr merge effort/99-demo .*--squash' "effort_close squash-merges the PR"
tc "$GH_LOG" 'issue close 101'  "effort_close closes sub #101"
tc "$GH_LOG" 'issue close 99 '  "effort_close closes the parent"
case "$close_out" in *"metrics:"*) echo "ok: capture_effort_metrics composed into close" ;; *) echo "FAIL: no metrics capture in close"; fail=1 ;; esac
# #148: board Status=Done for the parent + EVERY sub, set by the verb (was skill-only before)
tc "$BOARD_LOG" 'ITEM-99 SF1 OPT_DONE'  "effort_close sets board Done for the parent"
tc "$BOARD_LOG" 'ITEM-101 SF1 OPT_DONE' "effort_close sets board Done for sub #101"
tc "$BOARD_LOG" 'ITEM-102 SF1 OPT_DONE' "effort_close sets board Done for sub #102"
# #148: kit-sync drift check moved into the verb — a kit-managed path in the diff → advisory warning
case "$close_out" in *"kit-sync"*".claude/skills/demo.md"*) echo "ok: kit-sync drift check warns on kit-managed files" ;; *) echo "FAIL: no kit-sync warning in close output"; fail=1 ;; esac
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
SH
chmod +x "$stub/khook"
start_out="$(effort_start 88 forced 2>/dev/null)"
cd "$tmp/work/.claude/worktrees/effort+88-forced"
: > "$GH_LOG"
forced_out="$(KHOOK_MARKER="$tmp/khook.out" KIT_EFFORT_KNOWLEDGE_HOOK="$stub/khook" KIT_FORCE=1 effort_close 88 2>&1)"
cd "$tmp/work"
tc "$GH_LOG" 'pr merge effort/88-forced .*--squash' "KIT_FORCE=1 close merges despite no trace"
t  "knowledge-ingest hook ran with the effort number" "$(cat "$tmp/khook.out" 2>/dev/null)" "ingested 88"
# #148: no kit-managed file touched → the drift check stays silent
case "$forced_out" in *"kit-sync"*) echo "FAIL: kit-sync warning fired with no kit-managed change"; fail=1 ;; *) echo "ok: drift check silent when no kit-managed file changed" ;; esac

# ── effort_close #164: WAVE-style close — subs merged as individual task PRs, no effort branch ──
# Run from the main checkout on a non-effort branch with NO effort/<N>-* branch anywhere: the close
# must dispatch to the wave path instead of demanding the integration branch.

# refuse: a sub still open / lacking a merged PR → list the stragglers, close nothing
: > "$GH_LOG"
close_out="$(effort_close 78 2>&1)"; rc=$?
t  "wave close refuses while a sub is open (rc 1)" "$rc" "1"
case "$close_out" in *"not done"*"#202"*) echo "ok: wave refuse lists the straggler sub" ;; *) echo "FAIL: wave refuse output: $close_out"; fail=1 ;; esac
t  "wave refuse closes nothing" "$(grep -c 'issue close' "$GH_LOG")" "0"

# happy: every sub CLOSED with a merged PR → trace from the PR diffs → parent closed, board Done
# for parent + subs, drift check fires off the union of the merged PR diffs
: > "$BOARD_LOG"
export KIT_PROJECTS_V2="true"
: > "$GH_LOG"
close_out="$(effort_close 77 2>&1)"; rc=$?
export KIT_PROJECTS_V2="false"
t  "wave close succeeds when all subs merged (rc 0)" "$rc" "0"
tc "$GH_LOG" 'pr diff 501' "wave close snapshots the merged sub PR diffs"
tc "$GH_LOG" 'issue close 77 ' "wave close closes the parent"
t  "wave close closes ONLY the parent (subs already closed)" "$(grep -c 'issue close' "$GH_LOG")" "1"
t  "wave close never squash-merges anything" "$(grep -c 'pr merge' "$GH_LOG")" "0"
tc "$BOARD_LOG" 'ITEM-77 SF1 OPT_DONE'  "wave close sets board Done for the parent"
tc "$BOARD_LOG" 'ITEM-301 SF1 OPT_DONE' "wave close sets board Done for sub #301"
tc "$BOARD_LOG" 'ITEM-302 SF1 OPT_DONE' "wave close sets board Done for sub #302"
case "$close_out" in *"kit-sync"*".claude/skills/demo.md"*) echo "ok: wave drift check reads the merged PR diffs" ;; *) echo "FAIL: no kit-sync warning in wave close output"; fail=1 ;; esac

[ "$fail" -eq 0 ] && echo "ALL OK (effort-ops)" || echo "effort-ops: FAILURES"
exit "$fail"
