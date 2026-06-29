---
name: kit-task-pr
description: Commit current changes, push the branch, open a PR with the right template, labels, milestone, and link to the parent issue (+ board if enabled).
when_to_use: When work on an issue branch is ready for review. Replaces ad-hoc `gh pr create`.
---

# kit-task-pr

Plugin-direct skill — thin caller over the ONE canonical home
`${CLAUDE_PLUGIN_ROOT}/scripts/lib/kit-task-ops.sh` (`kto_task_pr`). The verb logic lives there,
never inline here (kit-engine-boundary #1/#2). The op respects `KIT_BASE_BRANCH` (default `develop`)
and the `KIT_PROJECTS_V2` board toggle, so the same code serves any project.

## Inputs

| Field          | Required | Notes                                                      |
| -------------- | -------- | ---------------------------------------------------------- |
| Issue number   | ✓        | Derived from branch name `<kind>/<N>-<slug>` if not passed |
| Summary        | ✓        | 1–3 bullets — the PR body's `## Summary`                   |
| Commit message | optional | Defaults to `<role>: <issue title>`                        |

Ask via `AskUserQuestion` when the Summary is missing — never invent it.

## Execution

```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/kit-config.sh" && load_kit_config
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/role-identity.sh"
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/gh-project.sh"
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/kit-task-ops.sh"

kto_task_pr "" "$SUMMARY"            # issue # parsed from the branch
# kto_task_pr 173 "$SUMMARY" "tech-lead: admin Clerk sign-in"   # explicit
```

The function prints `✓ <PR-URL>`.

## Rules

- Never open a PR for a branch off the `<kind>/<N>-<slug>` convention — the op aborts with instructions
- Never invent a Summary — ask if missing (the op refuses an empty Summary) · never push to the base branch directly
- PR mirrors issue labels · if no milestone, the op omits it (no block)
- If `gh pr create` fails because the branch hasn't diverged, the op surfaces the error verbatim (likely forgot to commit)
