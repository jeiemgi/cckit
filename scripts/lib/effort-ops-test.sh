#!/usr/bin/env bash
# shellcheck shell=bash
# effort-ops-test.sh — covers the effort lifecycle ops (#48). Hermetic: stubs gh (no network/auth)
# and uses a throwaway git repo with a bare remote. Run:  bash scripts/lib/effort-ops-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
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
effort_new --depends-on "#4,9" "depends on effort" >/dev/null 2>&1
tc "$GH_LOG" '^## Relations$'    "--depends-on writes ## Relations on its own line"
tc "$GH_LOG" '^- Depends on #4$' "--depends-on writes the first dep on its own line"
tc "$GH_LOG" '^- Depends on #9( |$)' "--depends-on writes the second dep on its own line"
t  "--depends-on does not mangle the heading" "$(grep -c '## Relations-' "$GH_LOG")" "0"

# ── #243 · effort_chain — a linear blocked_by chain, idempotent, cycle-refusing ────────────────────
# Its own gh stub (prepended to PATH) with real STATE: which issues exist, the blocked_by edge set,
# and per-issue bodies — so the edges and the body lines can be asserted, not just the call log.
cstub="$tmp/cbin"; mkdir -p "$cstub"
export CH_DIR="$tmp/chain"; mkdir -p "$CH_DIR"
export CH_LOG="$CH_DIR/gh.log" CH_EDGES="$CH_DIR/edges" CH_EXISTS="$CH_DIR/exists"
printf '501\n502\n503\n504\n601\n' > "$CH_EXISTS"   # #999 deliberately absent
: > "$CH_EDGES"; : > "$CH_LOG"
for n in 501 502 503 504; do printf '## Goal\ng%s\n\n## Verification\nv\n' "$n" > "$CH_DIR/body.$n"; done
cat > "$cstub/gh" <<'SH'
#!/usr/bin/env bash
# stub gh with state. DB id of issue N is 900000+N (the dependencies API takes the blocker's db id).
echo "$*" | tr '\n' ' ' >> "$CH_LOG"; echo >> "$CH_LOG"
_n() { printf '%s' "$1" | sed -nE 's#.*issues/([0-9]+).*#\1#p'; }
case "$1" in
  issue)
    case "$2" in
      view) cat "$CH_DIR/body.$3" 2>/dev/null; exit 0 ;;
      edit) n="$3"; shift 3
            # CH_FAIL_EDIT=<n> makes the edit fail for that issue — a POST-validation failure, the
            # only way to reach effort_chain's rc=1 path (pre-flight refusals never write at all).
            [ -n "${CH_FAIL_EDIT:-}" ] && [ "$n" = "$CH_FAIL_EDIT" ] && exit 1
            while [ $# -gt 0 ]; do
              [ "$1" = "--body" ] && { printf '%s' "$2" > "$CH_DIR/body.$n"; break; }
              shift
            done
            exit 0 ;;
      *) exit 0 ;;
    esac ;;
  api)
    case "$*" in
      *"--method POST"*"/dependencies/blocked_by"*)
        n="$(_n "$*")"; bid="$(printf '%s' "$*" | sed -nE 's#.*issue_id=([0-9]+).*#\1#p')"
        b=$((bid - 900000))
        grep -qx "$n $b" "$CH_EDGES" && exit 1     # GitHub rejects a duplicate edge
        echo "$n $b" >> "$CH_EDGES"; exit 0 ;;
      *"/dependencies/blocked_by"*)
        awk -v k="$(_n "$*")" '$1==k{print $2}' "$CH_EDGES"; exit 0 ;;
      *".id"*)     n="$(_n "$*")"; echo $((900000 + n)); exit 0 ;;
      *".number"*) n="$(_n "$*")"; grep -qx "$n" "$CH_EXISTS" || exit 1; echo "$n"; exit 0 ;;
      *) exit 0 ;;
    esac ;;
  *) exit 0 ;;
esac
SH
chmod +x "$cstub/gh"
export PATH="$cstub:$PATH"
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
t "chain re-run POSTs no dependency"         "$(grep -c 'method POST' "$CH_LOG")" "0"
t "chain re-run edits no body"               "$(grep -c 'issue edit' "$CH_LOG")" "0"
t "chain re-run leaves ONE Depends on line"  "$(grep -c 'Depends on #501' "$CH_DIR/body.502")" "1"
# a `#`-prefixed number is the same issue
: > "$CH_LOG"
effort_chain '#501' '#502' >/dev/null 2>&1
t "chain accepts #-prefixed numbers"         "$(grep -c 'method POST' "$CH_LOG")" "0"

# arity: fewer than two numbers is a usage error and writes nothing
: > "$CH_LOG"
effort_chain 501 >/dev/null 2>&1 && rc=0 || rc=1
t "chain refuses a single issue (rc 1)"      "$rc" "1"
effort_chain >/dev/null 2>&1 && rc=0 || rc=1
t "chain refuses zero issues (rc 1)"         "$rc" "1"
t "chain arity refusal writes nothing"       "$(grep -cE 'method POST|issue edit' "$CH_LOG")" "0"

# a non-numeric argument is rejected up front
: > "$CH_LOG"
effort_chain 501 not-a-number >/dev/null 2>&1 && rc=0 || rc=1
t "chain refuses a non-numeric arg (rc 1)"   "$rc" "1"
t "chain non-numeric refusal writes nothing" "$(grep -cE 'method POST|issue edit' "$CH_LOG")" "0"

# a nonexistent issue aborts the WHOLE chain — the earlier, valid link is not written either
: > "$CH_LOG"
effort_chain 504 999 >/dev/null 2>&1 && rc=0 || rc=1
t "chain refuses a nonexistent issue (rc 1)" "$rc" "1"
t "chain missing-issue refusal writes nothing" "$(grep -cE 'method POST|issue edit' "$CH_LOG")" "0"
t "chain missing-issue refusal adds no edge" "$(edges)" "502 501;503 502;"

# a repeated number is a cycle (`chain 1 2 1`) — refused whole
: > "$CH_LOG"
effort_chain 504 501 504 >/dev/null 2>&1 && rc=0 || rc=1
t "chain refuses a repeated number (rc 1)"   "$rc" "1"
t "chain repeat refusal writes nothing"      "$(grep -cE 'method POST|issue edit' "$CH_LOG")" "0"

# a cycle through edges GitHub ALREADY holds: 503 → 502 → 501 exists, so 501 blocked_by 503 loops
: > "$CH_LOG"
effort_chain 503 501 >/dev/null 2>&1 && rc=0 || rc=1
t "chain refuses a transitive cycle (rc 1)"  "$rc" "1"
t "chain cycle refusal writes nothing"       "$(grep -cE 'method POST|issue edit' "$CH_LOG")" "0"
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
# `gh` on PATH here is the chain stub, which logs to $CH_LOG — that is the log a refusal must leave
# empty, so the "writes nothing" assertions read it rather than $GH_LOG.

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
# …and the refusal writes NOTHING: no branch, no worktree dir, not even a gh call.
t "wip: refusal created no branch"   "$(wip_started 703-three)" "no"
t "wip: refusal created no worktree" "$(ls -d .claude/worktrees/effort+703-three 2>/dev/null | wc -l | tr -d ' ')" "0"
t "wip: refusal made no gh call"     "$(grep -c . "$CH_LOG" | tr -d ' ')" "0"

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

[ "$fail" -eq 0 ] && echo "ALL OK (effort-ops)" || echo "effort-ops: FAILURES"
exit "$fail"
