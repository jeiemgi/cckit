---
name: kit-cleanup
description: Run the ONE guided destructive sweep over the repo — present the gc plan (SAFE / ORPHAN / PROTECTED / stashes), then delete only the SAFE rows after the user confirms. Orphan branches, open-issue branches, and stashes are surfaced and left alone.
when_to_use: When `cckit gc` (or the SessionStart hygiene hook) reports merged branches and worktrees piling up and you want them gone in one pass. Use this instead of hand-rolling `git branch -D` + `git push origin --delete` loops. For the read-only report alone, use `/kit-gc`.
---

# kit-cleanup — the guided destructive sweep

Plugin-direct skill — helpers resolve from `${CLAUDE_PLUGIN_ROOT}`.

`/kit-gc` classifies; **this skill acts on that classification.** It is the only place in the kit
that deletes a branch the user did not name, so the whole design is plan-first.

**Safety contract:** the plan names **everything** `--yes` can touch — branches *and* worktrees, so
no deletion escapes the user's veto. `--yes` is the only thing that deletes a **cleanup target** (a
branch, a worktree, a remote ref), and three buckets are not deletable at all. A plan-only run still
prunes stale *remote-tracking metadata*, because it refreshes them to classify — see step 3. Table
below. It reuses
`kit_gc_analyze` as the single classifier rather than re-deriving verdicts, so `gc` and `cleanup`
can never disagree about what is safe to delete.

## Execution

### 1. Show the plan (read-only)

```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/kit-config.sh" && load_kit_config
KIT_GC_REPO="$KIT_REPO" source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/kit-gc.sh"
kit_gc_cleanup          # plan only — deletes no branch, worktree, remote ref or stash
```

Or through the CLI: `cckit cleanup` (add `--llm` for JSON counts).

### 2. Present it and ask

Show the user the bucket table and **ask for confirmation before running with `--yes`**. Let them
veto per-bucket — if they want the orphans looked at first, do that before deleting anything.

| Bucket | Rule | `--yes` does |
| --- | --- | --- |
| **SAFE** | PR `MERGED`, issue closed/absent, unprotected | **deletes** the worktree, the local branch, and the remote ref *if* the branch was level with it |
| **PROTECTED** | associated issue **still OPEN** | **keeps** — close the issue first |
| **ORPHAN** | local commits not on the base branch's remote, no merged PR | **keeps** — offer to recover into a PR (step 4) |
| **stashes** | any stash entry | **keeps** — irreversible; drop only after showing each diff |

### 3. Execute

```bash
kit_gc_cleanup --yes    # or: cckit cleanup --yes
```

Level-ness is recorded **before** the local prune — once the local ref is gone there is nothing left
to compare. It requires **exact equality in both directions**: `origin/<b>..<b>` alone only proves
local ⊆ remote, so a remote-ahead branch would otherwise lose remote-only history. A local delete is
likewise skipped when the branch is ahead of its remote (`git branch -D` is a force delete). A remote
delete that fails (protected ref, already gone) is reported, counted on the `remote deletes failed`
line (`remote_failed` in `--llm`), and makes the verb exit non-zero — a partial sweep is never
reported as a complete one. It is never retried blindly.

The plan-only path does perform one write: `kit_gc_analyze` refreshes remote-tracking refs
(`git fetch --prune`) so the classification is not made against a stale remote. It touches no branch,
worktree, stash, or commit.

### 4. Orphan handling

For each orphan with unique unpushed work: **do not delete.** Recover it into a clean PR off the base
branch (branch from `$BASE`, `git checkout <orphan> -- <paths>`, commit, push, open a PR) so the user
decides merge vs close. Same contract as `/kit-gc` step 4.

## Rules

- **Plan first, always.** Never run `--yes` before the user has seen the plan and said go.
- **Never** delete an ORPHAN branch, a PROTECTED branch, or a stash — those are irreversible or hold
  the only copy of work. `cleanup` cannot do it; do not work around it with raw git.
- **Never** delete the base branch (`main`/`develop`) or an open-PR branch — the classifier keeps
  both, and that is load-bearing, not incidental.
- A **dirty worktree is skipped with a warning**, not destroyed (recover-before-prune).
- If the protection helper cannot load, the sweep **aborts** rather than classify anything — a wrong
  "safe" is far worse than a refusal. Same contract as `/kit-gc`.
