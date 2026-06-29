# Task Management

## Source of truth

- **GitHub issues** in `{{GH_REPO}}`<!-- IF:PROJECTS_V2 --> + the Projects v2 board (`https://github.com/users/{{GH_OWNER}}/projects/{{PROJECT_NUMBER}}`)<!-- /IF:PROJECTS_V2 -->
- **Never** maintain task lists in markdown files. Use `gh issue` + the `task-*` skills so state stays in one place.
- Always re-fetch from `gh` — never trust a stale session snapshot.

## Roles

Every issue carries a `role:` label. Active roles for this project: {{ROLES_HUMAN}}.

The role determines which agent owns the work. Spawn that agent for the actual execution.

## Kinds

`task` · `plan` · `adr` · `scaffold` · `spike` — drives the branch prefix `<kind>/<N>-<slug>`.

## Priorities

`p1` (now / blocking) · `p2` (next) · `p3` (later).

## Milestones

{{MILESTONES_HUMAN}}

## The loop

1. `/kit-task-sync` — see the board, pick an unblocked issue
2. `/kit-task-start <N>` — branch from main, mark In Progress
3. Do the work (spawn the owning agent)
4. `/kit-task-pr <N>` — commit, push, open PR
5. `/kit-task-pr-merge` — squash-merge, back to main
6. `/kit-task-close <N>` — close issue<!-- IF:PLANS -->, archive plan if all deliverables merged<!-- /IF:PLANS -->

## Rules

- One PR per issue — no monster PRs. **Exception: a coupled migration/DDL chain ships as ONE PR (and ideally one issue)** — don't fragment a sequenced migration set into a PR-per-file. Split only for genuinely independent migrations or a step needing its own review gate (data backfill, RLS behavior change).
- PR title = issue title · body includes `Closes #N`
- Labels + milestone inherited from the issue
- Never file an issue without confirming title + role + priority with {{OWNER_NAME}}
- Never create new label families on the fly — fail loudly if a kind/priority is unknown
