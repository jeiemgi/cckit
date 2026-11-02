#!/usr/bin/env bash
# shellcheck shell=bash
# kit-gc-test.sh — covers the recover-before-prune contract (#111). A ZOMBIE worktree (working dir
# gone, admin metadata lingers) can hold staged-but-uncommitted work in its admin index — the sole
# blob->path map. `git worktree prune` deletes that index, orphaning the blobs (real data loss). gc
# must (a) detect zombies + staged deltas as their own analysis bucket, (b) recover any staged delta
# to its branch as a commit BEFORE pruning, and (c) never prune in a dry-run.
# Hermetic: a throwaway git repo, no network/gh. Run:  bash scripts/lib/kit-gc-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$ROOT/scripts/lib"
fail=0
t()  { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
has(){ case "$2" in *"$3"*) echo "ok: $1" ;; *) echo "FAIL: $1 -> '$2' lacks '$3'"; fail=1 ;; esac; }
command -v git >/dev/null 2>&1 || { echo "kit-gc-test: git required" >&2; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export KIT_GC_REPO="o/r"

# ── fabricate a zombie worktree with a staged delta ─────────────────────────────────────────────
cd "$tmp"
git init -q main
cd main
git config user.email t@t; git config user.name t
echo "base" > base.txt; git add base.txt; git commit -q -m "init"
init_branch="$(git rev-parse --abbrev-ref HEAD)"   # master or main, per the host git config
git worktree add -q ../wt -b feat/5-recover >/dev/null 2>&1
# Stage a NEW file inside the worktree (writes the worktree's admin index; the blob lands in the
# shared object store and so survives the worktree dir's death).
echo "precious staged work" > ../wt/keep.txt
git -C ../wt add keep.txt
TIP_BEFORE="$(git rev-parse --verify refs/heads/feat/5-recover)"
# Kill the worktree dir — the crash/ephemeral-mount death that leaves a zombie.
rm -rf ../wt

# shellcheck source=/dev/null
source "$LIB/kit-gc.sh"

# ── (a) detection: the zombie + its staged delta show up as their own bucket ─────────────────────
z="$(_kit_gc_zombies)"
has "zombie detected with its branch" "$z" "feat/5-recover"
case "$z" in *"	yes"*) echo "ok: zombie flagged as STAGED" ;; *) echo "FAIL: zombie not flagged staged: $z"; fail=1 ;; esac
analysis="$(kit_gc_analyze 2>/dev/null)"
has "analyze lists a zombies bucket" "$analysis" "# zombies"
has "analyze flags STAGED work in the zombie" "$analysis" "ZOMBIE with STAGED work"

# ── (c) dry-run recovers NOTHING (no new commit, admin dir intact) ──────────────────────────────
kit_gc_recover_zombies 0 >/dev/null 2>&1
t "dry-run leaves the branch tip unchanged" "$(git rev-parse --verify refs/heads/feat/5-recover)" "$TIP_BEFORE"
[ -d "$(git rev-parse --git-common-dir)/worktrees/wt" ] && echo "ok: dry-run leaves the admin dir intact" || { echo "FAIL: dry-run removed the admin dir"; fail=1; }

# ── (b) recover-before-prune: the staged delta lands as a commit on the branch ──────────────────
kit_gc_recover_zombies 1 >/dev/null 2>&1
TIP_AFTER="$(git rev-parse --verify refs/heads/feat/5-recover)"
[ "$TIP_AFTER" != "$TIP_BEFORE" ] && echo "ok: recovery advanced the branch to a new commit" || { echo "FAIL: branch tip did not advance"; fail=1; }
t "the recovered commit's parent is the old tip" "$(git rev-parse --verify "${TIP_AFTER}^")" "$TIP_BEFORE"
# The staged file is present in the recovered commit's tree with its exact content.
has "recovered commit carries the staged file" "$(git ls-tree -r --name-only "$TIP_AFTER")" "keep.txt"
t "recovered file content is intact" "$(git show "$TIP_AFTER:keep.txt")" "precious staged work"

# ── prune gating: `git worktree prune` only removes the admin dir after recovery ─────────────────
git worktree prune 2>/dev/null || true
[ -d "$(git rev-parse --git-common-dir)/worktrees/wt" ] && { echo "FAIL: admin dir survived prune"; fail=1; } || echo "ok: admin dir pruned after the work was recovered"

# ── #124: single-call PR index + local lookup ───────────────────────────────────────────────────
IDX="$(printf 'feat/1-a\tPR#11 MERGED\nfeat/2-b\tPR#22 OPEN')"
t "pr index lookup finds a branch"        "$(_kit_gc_pr_for "$IDX" feat/1-a)" "PR#11 MERGED"
t "pr index lookup finds another branch"  "$(_kit_gc_pr_for "$IDX" feat/2-b)" "PR#22 OPEN"
t "pr index lookup misses an absent branch" "$(_kit_gc_pr_for "$IDX" feat/9-z)" ""

# kit_gc_analyze must issue exactly ONE `gh pr list` regardless of branch count (no per-branch N+1).
git branch feat/30-x >/dev/null 2>&1; git branch feat/31-y >/dev/null 2>&1; git branch feat/32-z >/dev/null 2>&1
stub="$tmp/ghbin"; mkdir -p "$stub"
cat > "$stub/gh" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$GH_CALLS"
case "$1 $2" in
  "pr list") printf 'feat/30-x\tPR#30 MERGED\n' ;;
  "issue view") echo "open" ;;
  *) : ;;
esac
SH
chmod +x "$stub/gh"
export GH_CALLS="$tmp/ghcalls"; : > "$GH_CALLS"
PATH="$stub:$PATH" KIT_GC_REPO="o/r" kit_gc_analyze >/dev/null 2>&1
t "kit_gc_analyze makes exactly ONE gh pr list call" "$(grep -c '^pr list' "$GH_CALLS")" "1"

# ── the protection helper is MANDATORY (#219) ───────────────────────────────────────────────────
# With worktree-issue.sh absent, `wt_protected_reason` is undefined and every issue-open check would
# return empty — i.e. the whole repo classifies as SAFE to delete. Both entry points must FATAL out
# instead of emitting a deletion plan. Copy kit-gc.sh ALONE into a dir so the sibling cannot load.
lone="$tmp/lone"; mkdir -p "$lone"; cp "$LIB/kit-gc.sh" "$lone/kit-gc.sh"
out="$(bash -c "unset -f wt_protected_reason 2>/dev/null; . '$lone/kit-gc.sh'; kit_gc_analyze" 2>&1)"; rc=$?
t   "kit_gc_analyze refuses without worktree-issue.sh (rc)" "$rc" "1"
has "kit_gc_analyze says why it refused"                    "$out" "FATAL"
# and it must stop BEFORE the table. `kit_gc_analyze` prints `# <section>` headers and indented
# `  <name> -> <VERDICT>` rows, so match THOSE — an assertion aimed at the wrong shape passes
# vacuously no matter what the refusal prints.
t   "refusal emits no section header"                       "$(printf '%s\n' "$out" | grep -cE '^# ')"    "0"
t   "refusal emits no classification row"                   "$(printf '%s\n' "$out" | grep -cE ' -> ')"   "0"
out="$(bash -c ". '$lone/kit-gc.sh'; kit_gc_prune" 2>&1)"; rc=$?
t   "kit_gc_prune refuses without worktree-issue.sh (rc)"    "$rc" "1"

# ── kit_gc_cleanup: plan first, and the three irreversible buckets survive --yes (#226) ─────────
# A merged branch is SAFE; a branch whose issue is still OPEN is PROTECTED; a branch with local
# commits and no PR is ORPHAN. Only the first may ever be deleted, and never without --yes.
git branch task/40-merged  >/dev/null 2>&1
git branch task/41-open    >/dev/null 2>&1
# The orphan carries ONE commit base never received — a branch level with base would be LANDED (#388).
git checkout -q -b task/42-orphan
echo "only here" > orphan.txt; git add orphan.txt; git commit -qm "orphan work"
git checkout -q "$init_branch"
cat > "$stub/gh" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$GH_CALLS"
case "$1 $2" in
  "pr list")   printf 'task/40-merged\tPR#40 MERGED\n' ;;
  "issue view")
    for a in "$@"; do case "$a" in 41) echo open; exit 0 ;; esac; done
    echo closed ;;
  *) : ;;
esac
SH
chmod +x "$stub/gh"

plan="$(PATH="$stub:$PATH" KIT_GC_REPO="o/r" kit_gc_cleanup 2>&1)"
has "cleanup prints a plan"                    "$plan" "# cleanup plan"
has "cleanup says it deleted nothing"          "$plan" "PLAN ONLY"
has "cleanup counts the merged branch as SAFE" "$plan" "task/40-merged"
# Findings from review: the plan must NAME the kept buckets, not just count them — a user cannot
# veto what they cannot see.
has "plan names the protected branch"          "$plan" "task/41-open"
has "plan names the orphan branch"             "$plan" "task/42-orphan"
has "plan has a SAFE worktrees bucket"         "$plan" "SAFE worktrees"
# The ZOMBIE bucket (#227 review): --yes recovers a zombie's staged delta to its branch and then
# prunes its metadata, so the plan MUST name those rows too — otherwise --yes acts on a row the
# user never saw. Needs its OWN zombie: the one fabricated at the top of this file was already
# pruned by the "prune gating" step above.
git worktree add -q ../wt2 -b feat/6-zombie2 >/dev/null 2>&1
echo "staged in the second zombie" > ../wt2/keep2.txt
git -C ../wt2 add keep2.txt
Z2_TIP_BEFORE="$(git rev-parse --verify refs/heads/feat/6-zombie2)"
rm -rf ../wt2
zplan="$(PATH="$stub:$PATH" KIT_GC_REPO="o/r" kit_gc_cleanup 2>&1)"
has "plan has a ZOMBIE worktrees bucket"       "$zplan" "ZOMBIE worktrees"
has "plan names the zombie worktree"           "$zplan" "wt2 [feat/6-zombie2]"
has "plan says the staged work is recovered first" "$zplan" "STAGED work — recovered to a commit"
t   "zombie counted in the plan" \
    "$(printf '%s\n' "$zplan" | awk '/^  ZOMBIE worktrees/{print $3}')" "1"
# Still plan-only: neither the metadata nor the branch tip may move.
if [ -d "$(git rev-parse --git-common-dir)/worktrees/wt2" ]; then
  echo "ok: plan-only left the zombie metadata intact"
else
  echo "FAIL: plan-only pruned the zombie metadata"; fail=1
fi
t "plan-only left the zombie branch tip alone" \
  "$(git rev-parse --verify refs/heads/feat/6-zombie2)" "$Z2_TIP_BEFORE"

applied="$(PATH="$stub:$PATH" KIT_GC_REPO="o/r" kit_gc_cleanup --yes 2>&1)"
t   "--yes deleted the merged branch"   "$(git branch --list task/40-merged | wc -l | tr -d ' ')" "0"
t   "--yes KEPT the open-issue branch"  "$(git branch --list task/41-open   | wc -l | tr -d ' ')" "1"
t   "--yes KEPT the orphan branch"      "$(git branch --list task/42-orphan | wc -l | tr -d ' ')" "1"
has "cleanup reports what it left"      "$applied" "left untouched"
# --yes is where the zombie metadata is allowed to go — but only AFTER its staged work is a commit.
if [ -d "$(git rev-parse --git-common-dir)/worktrees/wt2" ]; then
  echo "FAIL: --yes left the zombie metadata behind"; fail=1
else
  echo "ok: --yes pruned the zombie metadata it listed"
fi
Z2_TIP_AFTER="$(git rev-parse --verify refs/heads/feat/6-zombie2)"
if [ "$Z2_TIP_AFTER" != "$Z2_TIP_BEFORE" ]; then
  echo "ok: --yes recovered the zombie's staged work before pruning"
else
  echo "FAIL: zombie metadata pruned without recovering its staged work"; fail=1
fi
has "the recovered commit carries the staged file" "$(git ls-tree -r --name-only "$Z2_TIP_AFTER")" "keep2.txt"
has "cleanup counts the zombies it pruned" "$applied" "zombie pruned"
# The failed-remote-delete count must be a real number the plan prints, not just an exit status —
# the skill promises it and `--llm` serializes it as `remote_failed`.
t   "cleanup prints a remote-failure count" \
    "$(printf '%s\n' "$applied" | awk '/^  remote deletes failed/{print $4}')" "0"

# ── ref-comparison guards: a merged PR alone must NEVER authorize a force delete (#226 review) ──
# `git branch -D` destroys unpushed commits, and one-directional containment does not prove equality.
git checkout -q -b task/43-ahead 2>/dev/null
echo ahead > ahead.txt; git add ahead.txt; git commit -qm "unpushed work"
# Fabricate a remote-tracking ref that does NOT contain this commit, so the branch is "ahead".
git update-ref "refs/remotes/origin/task/43-ahead" "$(git rev-parse HEAD~1)"
git checkout -q "$init_branch"

t "_kit_gc_has_unpushed sees the ahead branch"    "$(_kit_gc_has_unpushed task/43-ahead && echo yes || echo no)" "yes"
t "_kit_gc_has_unpushed clears a level branch"    "$(_kit_gc_has_unpushed task/42-orphan && echo yes || echo no)" "no"
# Remote-ahead is the OTHER direction: local ⊆ remote passes the level check but the remote holds
# history the local does not, so deleting the remote would lose it.
git update-ref "refs/remotes/origin/task/44-behind" "$(git rev-parse task/43-ahead)"
git branch task/44-behind "$(git rev-parse task/43-ahead~1)" 2>/dev/null
t "_kit_gc_remote_ahead sees remote-only history" "$(_kit_gc_remote_ahead task/44-behind && echo yes || echo no)" "yes"
t "_kit_gc_has_unpushed clears it (local ⊆ remote)" "$(_kit_gc_has_unpushed task/44-behind && echo yes || echo no)" "no"

# End to end: a MERGED PR on a branch with unpushed commits must survive --yes.
cat > "$stub/gh" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "pr list")    printf 'task/43-ahead\tPR#43 MERGED\n' ;;
  "issue view") echo closed ;;
  *) : ;;
esac
SH
chmod +x "$stub/gh"
out="$(PATH="$stub:$PATH" KIT_GC_REPO="o/r" kit_gc_prune --yes 2>&1)"
t   "merged-but-ahead branch survives prune --yes" "$(git branch --list task/43-ahead | wc -l | tr -d ' ')" "1"
has "prune says why it skipped it"                 "$out" "unpushed commits"

# ── #388: LANDED — no PR of its own, work already on base ──────────────────────────────────────
# A squash merge rewrites the patch ids, so neither `git cherry` nor `--is-ancestor` can see that
# a sub branch's work reached base. gc must classify these rows LANDED (not ORPHAN), the plan must
# list them as their own block, and --yes must delete them — worktree included — while a true
# orphan (one commit whose content base never received) stays untouched.
export KIT_BASE_BRANCH="$init_branch"
# Earlier fixtures that are level with base read as LANDED now (ancestor of base); drop them so the
# counts below are this section's alone (task/41-open stays PROTECTED, the others ORPHAN).
git branch -D task/44-behind feat/30-x feat/31-y feat/32-z >/dev/null 2>&1
git update-ref -d refs/remotes/origin/task/44-behind 2>/dev/null
# (1) an effort sub, squash-landed: sub/50a commits sub.txt; "the effort PR" lands the same content
#     on base as ONE new commit — check (a), content.
git checkout -q -b sub/50a-part
echo "sub work" > sub.txt; git add sub.txt; git commit -qm "sub: part"
git checkout -q "$init_branch"
git checkout -q sub/50a-part -- sub.txt; git commit -qm "feat(effort): squash of effort 50"
# (2) a Claude Code Agent-tool isolation worktree (`worktree-agent-<hash>`), squash-landed too.
git worktree add -q ../agentwt -b worktree-agent-abc123 >/dev/null 2>&1
echo "agent work" > ../agentwt/agent.txt; git -C ../agentwt add agent.txt; git -C ../agentwt commit -qm "agent: part"
git checkout -q worktree-agent-abc123 -- agent.txt; git commit -qm "feat: squash of the agent's work"
# (3) a second sub whose file base has since CHANGED — content check fails, so only lineage (check
#     b: issue #50 closed + effort/50 PR merged) can land it.
git checkout -q -b sub/50b-other
echo "v1" > other.txt; git add other.txt; git commit -qm "sub: other"
git checkout -q "$init_branch"
git checkout -q sub/50b-other -- other.txt; git commit -qm "feat(effort): squash of sub 50b"
echo "v2" > other.txt; git add other.txt; git commit -qm "later change on base"
# (4) a true orphan: issue #51 is closed but nothing with its content ever reached base.
git checkout -q -b task/51-orphan
echo "never landed" > lost.txt; git add lost.txt; git commit -qm "orphan"
git checkout -q "$init_branch"
# (5) an agent worktree whose work landed but whose tree is DIRTY — recover-before-prune keeps it.
git worktree add -q ../agentwt2 -b worktree-agent-def456 >/dev/null 2>&1
echo "agent two" > ../agentwt2/agent2.txt; git -C ../agentwt2 add agent2.txt; git -C ../agentwt2 commit -qm "agent: two"
git checkout -q worktree-agent-def456 -- agent2.txt; git commit -qm "feat: squash of agent two"
echo "uncommitted" > ../agentwt2/scratch.txt

cat > "$stub/gh" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "pr list")    printf 'effort/50-thing\tPR#55 MERGED\n' ;;
  "issue view")
    for a in "$@"; do case "$a" in 41) echo open; exit 0 ;; esac; done
    echo closed ;;
  *) : ;;
esac
SH
chmod +x "$stub/gh"

analysis="$(PATH="$stub:$PATH" KIT_GC_REPO="o/r" kit_gc_analyze 2>/dev/null)"
row() { printf '%s\n' "$analysis" | awk -v b="$1" '$1==b && $2=="->"{sub(/^  [^ ]+ -> /, ""); print; exit}'; }
has "squash-landed sub is LANDED by content"       "$(row sub/50a-part)"           "LANDED (content on $init_branch)"
has "agent worktree branch is LANDED and named"    "$(row worktree-agent-abc123)"  "LANDED (agent worktree; content on $init_branch)"
has "sub with later base change is LANDED by lineage" "$(row sub/50b-other)"      "LANDED (issue #50 closed, its PR merged)"
has "true orphan stays ORPHAN"                     "$(row task/51-orphan)"         "ORPHAN"
has "dirty agent worktree's branch is still LANDED" "$(row worktree-agent-def456)" "LANDED"
t   "has_prunable sees a LANDED row"               "$(PATH="$stub:$PATH" KIT_GC_REPO="o/r" kit_gc_has_prunable && echo yes || echo no)" "yes"

plan="$(PATH="$stub:$PATH" KIT_GC_REPO="o/r" kit_gc_cleanup 2>&1)"
has "plan has a LANDED block"                      "$plan" "LANDED branches"
t   "plan counts the four LANDED rows" \
    "$(printf '%s\n' "$plan" | awk '/^  LANDED branches/{print $3}')" "4"
has "plan names the sub with its reason"           "$plan" "sub/50a-part (content on $init_branch)"
has "plan names the agent worktree as a worktree"  "$plan" "agentwt [worktree-agent-abc123]"
has "plan flags the dirty agent worktree"          "$plan" "agentwt2 [worktree-agent-def456] (DIRTY"
has "plan keeps the orphan"                        "$plan" "task/51-orphan"
# The LANDED block prints BEFORE the ORPHAN block.
t   "LANDED block precedes ORPHAN block" \
    "$(printf '%s\n' "$plan" | awk '/^  LANDED branches/{l=NR} /^  ORPHAN kept/{o=NR} END{print (l<o)?"yes":"no"}')" "yes"
t   "plan-only kept the sub branch"      "$(git branch --list sub/50a-part | wc -l | tr -d ' ')" "1"
[ -d ../agentwt ] && echo "ok: plan-only kept the agent worktree" || { echo "FAIL: plan-only removed the agent worktree"; fail=1; }

# kit_gc_prune --only: the scope effort_close uses to collect ONE effort's subs (#388) — the agent
# branch is also LANDED but outside the glob, so it must survive this pass.
out="$(PATH="$stub:$PATH" KIT_GC_REPO="o/r" kit_gc_prune --yes --only '^sub/50[a-z]-' 2>&1)"
t   "--only deleted the content-landed sub"   "$(git branch --list sub/50a-part  | wc -l | tr -d ' ')" "0"
t   "--only deleted the lineage-landed sub"   "$(git branch --list sub/50b-other | wc -l | tr -d ' ')" "0"
t   "--only left the agent branch alone"      "$(git branch --list worktree-agent-abc123 | wc -l | tr -d ' ')" "1"
has "prune says why the sub went"             "$out" "deleted local branch sub/50a-part (LANDED"

applied="$(PATH="$stub:$PATH" KIT_GC_REPO="o/r" kit_gc_cleanup --yes 2>&1)"
t   "--yes deleted the agent branch"          "$(git branch --list worktree-agent-abc123 | wc -l | tr -d ' ')" "0"
[ -d ../agentwt ] && { echo "FAIL: --yes left the agent worktree dir"; fail=1; } || echo "ok: --yes removed the agent worktree"
t   "--yes KEPT the true orphan"              "$(git branch --list task/51-orphan | wc -l | tr -d ' ')" "1"
t   "--yes KEPT the dirty agent worktree's branch" "$(git branch --list worktree-agent-def456 | wc -l | tr -d ' ')" "1"
[ -d ../agentwt2 ] && echo "ok: --yes skipped the dirty agent worktree" || { echo "FAIL: --yes destroyed a dirty worktree"; fail=1; }
has "cleanup said why it skipped the dirty one" "$applied" "SKIP dirty worktree"
has "cleanup counts what it landed"            "$applied" "landed deleted"

# ── lineage when the closing PR is OUTSIDE the 200-PR index window ─────────────────────────────
# Measured on tedos: PR#2218 (closed #2165) sat at position 254 of `gh pr list --state all`, so the
# index never carried it and 21 `worktree-agent-*` branches with `[#2165]` subjects stayed ORPHAN
# while base had changed their files again (content check fails too). The issue itself knows which
# PR closed it (`closedByPullRequestsReferences`), exact and not window-bound. Cached per issue: the
# two branches below both name #60 and must cost ONE `issue view … closedBy` call.
git checkout -q -b sub/60a-old
echo "old sub" > old.txt; git add old.txt; git commit -qm "sub: old"
git checkout -q "$init_branch"
git checkout -q sub/60a-old -- old.txt; git commit -qm "feat(effort): squash of effort 60"
echo "changed again" > old.txt; git add old.txt; git commit -qm "later change on base"
git checkout -q -b worktree-agent-old777
echo "agent old" > agentold.txt; git add agentold.txt; git commit -qm "feat: agent part [#60]"
git checkout -q "$init_branch"
git checkout -q worktree-agent-old777 -- agentold.txt; git commit -qm "squash of the agent's part"
echo "changed again" > agentold.txt; git add agentold.txt; git commit -qm "later change on base"
cat > "$stub/gh" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$GH_CALLS"
case "$1 $2" in
  "pr list") printf 'effort/50-thing\tPR#55 MERGED\n' ;;      # nothing for #60: scrolled out
  "issue view")
    case "$*" in
      *closedByPullRequestsReferences*) for a in "$@"; do case "$a" in 60) echo 61; exit 0 ;; esac; done ;;
      *) echo closed ;;
    esac ;;
  "pr view") for a in "$@"; do case "$a" in 61) echo MERGED; exit 0 ;; esac; done; echo CLOSED ;;
  *) : ;;
esac
SH
chmod +x "$stub/gh"
: > "$GH_CALLS"
analysis="$(PATH="$stub:$PATH" KIT_GC_REPO="o/r" kit_gc_analyze 2>/dev/null)"
has "sub landed via the issue's closing PR"        "$(row sub/60a-old)"            "LANDED (issue #60 closed by merged PR#61)"
has "agent branch with [#60] subject landed too"   "$(row worktree-agent-old777)"  "LANDED (agent worktree; issue #60 closed by merged PR#61)"
t   "the closedBy lookup ran ONCE for #60 across both branches" \
    "$(grep -c 'issue view 60 .*closedByPullRequestsReferences' "$GH_CALLS")" "1"
t   "the PR state was confirmed ONCE" "$(grep -c '^pr view 61' "$GH_CALLS")" "1"
# A fresh run must not trust the previous run's cache (the issue could have been reopened).
: > "$GH_CALLS"
PATH="$stub:$PATH" KIT_GC_REPO="o/r" kit_gc_prune >/dev/null 2>&1
t   "a new run looks the issue up again" "$(grep -c 'issue view 60 .*closedByPullRequestsReferences' "$GH_CALLS")" "1"
unset KIT_BASE_BRANCH

[ "$fail" -eq 0 ] && echo "ALL OK (kit-gc)" || echo "kit-gc: FAILURES"
exit "$fail"
