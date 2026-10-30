---
name: kit-effort-pr
description: Open the ONE pull request for an effort — `effort/<N>` → base branch — with a rich human-facing review body plus a `## For agents` section listing the file paths/entry points. Title `[Role] [#N] <title>`. Inherits labels + milestone from the parent issue and moves it to In Review on the board.
when_to_use: When an effort branch is ready for review (all its sub-issues built + merged into the effort branch). One effort = one PR (effort-model.md) — never open per-sub PRs to the base branch. Mirrors `kit-task-pr` for the effort lifecycle.
---

# kit-effort-pr

Thin caller of the verb **`cckit effort pr`** (`effort_pr` in `scripts/lib/effort-ops.sh`), the ONE
implementation (kit-engine-boundary #1/#2, #363). This skill used to carry its own inline copy of the
logic; agents copied that script by hand and the copy drifted (a PR missing from the board, a mangled
body). Never re-implement it here, and never paste it into a shell.

Opens the **single** PR for an effort. The PR carries the human-facing review write-up + a
`## For agents` section (retrieval context / the work record). The parent issue holds the plan;
this PR is where humans review the result. The title carries `[#N]` (the effort id) — mandatory
(effort-model.md, effort-id taxonomy).

## Inputs

| Field          | Required | Notes                                                       |
| -------------- | -------- | ----------------------------------------------------------- |
| Issue number   | optional | The **parent** effort #N — derived from `effort/<N>-<slug>` |
| Summary        | ✓        | The human review write-up (what changed + why)              |
| For agents     | ✓        | File paths / entry points — the PR's `## For agents` block  |
| Commit message | optional | Defaults to `<role>: <issue title>` for any pending changes |

## Execution

From the effort worktree (branch `effort/<N>-<slug>`):

```bash
cckit effort pr <N> --summary-file <summary.md> --for-agents-file <for-agents.md>
# short form: cckit effort pr <N> --summary "<what + why>" --for-agents "<paths>"
```

What the verb does, in order: commits pending **tracked** changes (role identity as a
`Co-authored-by` trailer; untracked files are listed, never swept in) → pushes → reads the parent's
title, labels and milestone → composes the title with `effort_pr_title` and refuses one without
`[#N]` → opens the PR with the body below → adds the PR to the board at In Review (+ Role) and moves
the parent to In Review. A failed board add prints a warning; it is never silent.

Body: `## For the orchestrator` (+ `Closes #N`) · `## Summary` · `## For agents` · `## Verification`.

## Output

- The single effort PR URL (title `[Role] [#N] <title>`)
- PR + parent issue both at In Review on the board (if Projects v2 is on)
- Suggested next: `/kit-effort-close <N>`

## Rules

- **ONE PR per effort** — `effort/<N>` → base branch. Never open a PR from a `sub/<N><letter>`
  branch to the base; sub-issues merge into the effort branch first (effort-model.md).
- The title MUST carry `[#N]` (the effort id) — a PR title without it is a review blocker
  (effort-model.md, effort-id taxonomy).
- The body MUST include both a human `## Summary` and a `## For agents` (file paths) — the latter is
  retrieval context + part of the work record.
- `Closes #$NUM` closes the **parent** on merge; the sub-issues are closed by `/kit-effort-close`
  (so their pre-squash diffs are snapshotted first).
- Never invent a Summary or For-agents block — ask if missing.
- Labels + milestone mirror the parent issue; never strip them.
- Never push to a release branch directly.
