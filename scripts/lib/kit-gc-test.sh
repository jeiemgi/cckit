#!/usr/bin/env bash
# shellcheck shell=bash
# kit-gc-test.sh — covers the recover-before-prune contract (#111). A ZOMBIE worktree (working dir
# gone, admin metadata lingers) can hold staged-but-uncommitted work in its admin index — the sole
# blob->path map. `git worktree prune` deletes that index, orphaning the blobs (real data loss). gc
# must (a) detect zombies + staged deltas as their own analysis bucket, (b) recover any staged delta
# to its branch as a commit BEFORE pruning, and (c) never prune in a dry-run.
# Hermetic: a throwaway git repo, no network/gh. Run:  bash scripts/lib/kit-gc-test.sh
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

[ "$fail" -eq 0 ] && echo "ALL OK (kit-gc)" || echo "kit-gc: FAILURES"
exit "$fail"
