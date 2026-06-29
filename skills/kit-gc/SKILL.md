---
name: kit-gc
description: Garbage-collect the repo — prune worktrees whose PR already merged, delete merged local + remote branches, surface orphan/unpushed commits and stale stashes, and flag issues whose PR merged but stayed open. Dry-run by default; destructive steps require explicit confirmation.
when_to_use: When the repo has accumulated stale branches, orphan worktrees, or stashes (the SessionStart hygiene hook flags this), or on demand to tidy before/after a chapter of work. Replaces the manual cleanup sweep.
---

# kit-gc — repo garbage collector

Plugin-direct skill — helpers resolve from `${CLAUDE_PLUGIN_ROOT}`.

Cleans what accumulates: merged-but-undeleted branches (local + remote), orphan
worktrees, stale stashes, orphan unpushed commits, and stale-open issues.

**Safety contract:** read-only **analysis first** → present a plan → only delete
after the user confirms. Never touch: the base branch (`main`/`develop`), branches
with an **open PR**, worktrees of an open-PR branch, **a branch/worktree whose
associated issue is still OPEN**, or branches/commits whose work is **not on the base
branch's remote** (orphan work is surfaced, never auto-deleted).

> **Worktree↔issue association.** A branch `<kind>/<N>-<slug>` (or worktree dir
> `<kind>+<N>-<slug>`) belongs to issue **#N** — derived from the name, not registered.
> `gc` resolves #N and **refuses to remove anything whose issue is still open, even
> with no PR yet** — this protects in-progress worktrees that haven't opened a PR.
> Helper: `${CLAUDE_PLUGIN_ROOT}/scripts/lib/worktree-issue.sh` (`wt_issue_number`, `wt_protected_reason`).

## Execution

### 1. Refresh + analyze (read-only)

```bash
# Read-only analysis lives in the CANONICAL Family-1 home — the skill is a thin caller (#419):
#   scripts/lib/kit-gc.sh :: kit_gc_analyze   (also what `kit gc` + the kit-ui cockpit run)
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/kit-config.sh" && load_kit_config
KIT_GC_REPO="$KIT_REPO" source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/kit-gc.sh"
kit_gc_analyze       # worktrees / branches / stashes, each tagged PROTECTED/SAFE/ACTIVE/ORPHAN
```

Classify every branch/worktree (issue-open protection wins over everything except an explicit force):

| Bucket | Rule | Action |
| --- | --- | --- |
| **Protected (open issue)** | `wt_protected_reason` non-empty — associated issue **#N still OPEN** | **keep** — never prune, even with no PR / merged PR |
| **Safe to delete** | PR `MERGED`, level with its remote (no unpushed commits), **and** issue closed/absent | prune |
| **Active** | open PR, or the base branch, or a worktree branch with an open PR | keep |
| **Orphan** | local commits **not on the base branch's remote** and no merged PR | **surface, never auto-delete** — offer to open a recovery PR |

For squash-merged branches, `--is-ancestor` is unreliable — trust the **PR state**, then verify the branch is level with its remote (`git rev-list --count origin/<b>..<b>` = 0) before deleting.

### 2. Present the plan

Print a table: worktrees to remove, branches to delete (local + remote), orphans to recover, stashes to drop, and stale-open issues (PR merged but issue still open). **Ask for confirmation** before any destructive step. Let the user veto per-bucket.

### 3. Execute (after confirmation)

```bash
# Worktrees whose PR merged
git worktree remove <path> --force && git worktree prune
# Merged branches — local then remote
git branch -D <branch>
git push origin --delete <branch>
# Stale-open issues (PR already merged)
gh issue close <n> --repo "$KIT_REPO" --reason completed --comment "Delivered via PR #<pr>."
# Stashes — only after showing each diff and getting an explicit OK
git stash drop 'stash@{n}'   # or: git stash clear
```

### 4. Orphan handling

For each orphan branch with unique unpushed work: **do not delete**. Recover it
into a clean PR off the base branch (branch from `$BASE`, `git checkout <orphan> --
<paths>`, commit, push, open PR) so the user decides merge vs close.

## Rules

- **Dry-run + confirm by default.** Never delete without showing the plan first.
- **Never** delete the base branch (`main`/`develop`) or an open-PR branch/worktree.
- **Never** remove a worktree/branch whose **associated issue is still open** (`wt_protected_reason` non-empty) — close the issue first, or pass an explicit per-item override.
- **Never** drop a stash or delete an orphan branch without explicit per-item consent (stashes and unpushed commits are irreversible).
- Verify a branch is **level with its remote** before deleting — an "ahead" branch may hold orphan work.
- Prefer enabling GitHub **"Automatically delete head branches"** so remote pruning stops being a manual step.
