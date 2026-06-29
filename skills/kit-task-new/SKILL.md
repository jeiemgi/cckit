---
name: kit-task-new
description: Create a new GitHub issue — applies labels, milestone, and (if enabled) Projects v2 fields in one flow. Prefer this over raw `gh issue create` so the board stays in sync.
when_to_use: When the owner or a sub-agent identifies a new piece of work to track.
---

# kit-task-new

Plugin-direct skill — thin caller over the ONE canonical home
`${CLAUDE_PLUGIN_ROOT}/scripts/lib/kit-task-ops.sh` (`kto_task_new`). The verb logic lives there,
never inline here (kit-engine-boundary #1/#2). The op respects `KIT_BASE_BRANCH` (for the Plan blob
link) and the `KIT_PROJECTS_V2` board toggle.

## What it does

One flow → creates a GitHub issue **and** (if Projects v2 is enabled) adds it to the board with Role, Status (Todo), and Plan Link set. Reads project config from `.claude/kit.config.json`.

## Inputs (ask via AskUserQuestion when missing — do not invent)

| Field      | Required | Notes                                         |
| ---------- | -------- | --------------------------------------------- |
| Title      | ✓        | Format: `[<role>] <imperative summary>`       |
| Role       | ✓        | One of the project's `roles` (see kit.config) |
| Kind       | ✓        | task / plan / adr / scaffold / spike          |
| Priority   | ✓        | p1 / p2 / p3                                  |
| Milestone  | ✓        | One of the project's `milestones`             |
| Plan link  | optional | Path under the project's plans dir            |
| Blocked by | optional | `#N, #M`                                      |
| Body       | ✓        | Context + DoD checklist + acceptance          |

Validate Kind/Priority/Role against the project's closed sets before dispatching — the op does not invent label families.

## Execution

```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/kit-config.sh" && load_kit_config
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/role-identity.sh"
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/gh-project.sh"
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/kit-task-ops.sh"

kto_task_new "$TITLE" "$ROLE" "$KIND" "$PRIORITY" "$MILESTONE" "$PLAN_LINK" "$BLOCKED_BY" "$USER_BODY"
```

The function prints `✓ <issue-URL>` and echoes the new issue number.

## Rules

- Never file without confirming title + role + priority with the owner
- Never create new label families on the fly — validate against the project's closed sets; fail loudly if a kind/priority/role is unknown
- If the milestone doesn't exist, ask before creating it
- Always assign `@me` — the op does this
