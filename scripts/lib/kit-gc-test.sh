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
git branch task/42-orphan  >/dev/null 2>&1
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

[ "$fail" -eq 0 ] && echo "ALL OK (kit-gc)" || echo "kit-gc: FAILURES"
exit "$fail"
