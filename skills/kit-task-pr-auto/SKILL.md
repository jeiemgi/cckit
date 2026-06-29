---
name: kit-task-pr-auto
description: Same as kit-task-pr (commit, push, open PR) then immediately attempts to merge via kit-task-pr-merge. One command to land a branch end-to-end.
when_to_use: When work is ready to ship without a separate review step.
---

# kit-task-pr-auto

Runs `/kit-task-pr` then `/kit-task-pr-merge` back-to-back.

## Inputs

Same as `kit-task-pr` — see `${CLAUDE_PLUGIN_ROOT}/skills/kit-task-pr/SKILL.md`.

## Execution

1. Execute the full `kit-task-pr` flow, capturing the PR URL/number.
2. Immediately execute the full `kit-task-pr-merge` flow using that PR number.

If the PR can't be merged immediately (draft, checks pending, conflicts), report the blocker and stop — do not loop or retry silently.

## Rules

- Inherits all rules from `kit-task-pr` and `kit-task-pr-merge`
- If `kit-task-pr` fails, stop — do not attempt merge
- If merge fails due to conflicts, attempt the rebase fix from `kit-task-pr-merge` before giving up
- Always end on the base branch with a clean pull on success
