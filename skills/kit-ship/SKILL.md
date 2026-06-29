---
name: kit-ship
description: End-to-end delivery for a user request — fix the issue, then run the full kit cycle (start → PR → CI → merge → close → update kit) using the kit-task commands. One command takes an open issue from code to merged-on-base with the board kept in sync.
when_to_use: When the user says "fix #N and ship it", "do the full cycle on #N", "fix this and merge it", or hands you a tracked issue to take all the way to the base branch. For just opening a PR use /kit-task-pr; for PR+merge with no implementation use /kit-task-pr-auto.
---

# kit-ship

Takes one issue from **open → implemented → merged on the base branch → closed → kit refreshed**,
chaining the existing kit-task commands. This is the orchestrator that wraps the manual sequence,
with the sharp edges baked in (see **Hard rules**). Plugin-direct — the kit-task skills it chains
resolve from `${CLAUDE_PLUGIN_ROOT}`.

## Inputs

| Field        | Required | Notes                                                                 |
| ------------ | -------- | --------------------------------------------------------------------- |
| Issue number | ✓*       | `157`. *If the user gives a request with no issue, create one first via `/kit-task-new`, then proceed. |
| Skip merge   | optional | `--pr-only` → stop after the PR (don't merge). Default merges.         |

## The cycle

| # | Step | Command / action |
| - | ---- | ---------------- |
| 1 | **Read the issue** | `gh issue view <N>` — understand scope. If ambiguous/large/decision-heavy → stop and ask (don't ship blind). |
| 2 | **Start** | `/kit-task-start <N> --worktree` — branch `<kind>/<N>-<slug>` from the fresh base branch, mark **In Progress**. |
| 3 | **Implement** | Do the actual work to the issue's acceptance criteria, following project conventions + the relevant agent's domain. |
| 4 | **Verify locally** | Run the affected workspace's `build` / `typecheck` / `lint` (e.g. `pnpm -F <pkg> build typecheck`) or `bash -n` for scripts. Don't open a PR on red. |
| 5 | **PR** | `/kit-task-pr <N>` — commit, push, open PR to the base branch, mirror labels/milestone, add to board, move issue **In Review**. |
| 6 | **Wait for CI** | If the project has a required check, poll until it's not pending (background `until` loop). **Pending ≠ failing — wait; never force-merge.** |
| 7 | **Merge** | `/kit-task-pr-merge` once green — squash to the base, switch to base, pull, delete local+remote branch + worktree. |
| 8 | **Close** | `gh issue close <N>` + set board **Done**. **Required** when `Closes #N` does NOT auto-fire (PRs that merge to a non-default branch don't trigger GitHub auto-close). |
| 9 | **Update kit (only if the change touched the plugin source)** | bump version (`/kit-dev ship`) + `/plugin update`. |

Report at the end: issue state, PR number + merged status, branch cleaned, board reflects Done.

## Hard rules

- **Don't ship blind.** If step 1 finds the issue ambiguous, large, or decision-heavy, stop and ask — this skill executes scoped work, it doesn't make product calls.
- **Never force-merge over pending CI.** Wait for the check. Only a *failing* (not pending) check stops the cycle — report it verbatim and stop.
- **Always close the issue manually** (step 8) when auto-close won't fire on the base branch. The board is the source of truth.
- **Always end on the base branch, clean.** Merged branch + worktree deleted; never leave the user on the feature branch.
- One issue → one PR. If scope balloons mid-implementation, stop and split rather than growing a monster PR.
