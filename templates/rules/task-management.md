# Task Management

## Source of truth

- **GitHub issues** in `{{GH_REPO}}`<!-- IF:PROJECTS_V2 --> + the Projects v2 board (`https://github.com/users/{{GH_OWNER}}/projects/{{PROJECT_NUMBER}}`)<!-- /IF:PROJECTS_V2 -->
- **Never** maintain task lists in markdown files. Use `gh issue` + the `task-*` skills so state stays in one place.
- Always re-fetch from `gh` — never trust a stale session snapshot.
<!-- IF:LIGHT_TASKS -->
- **This project's default list is light tasks** (`tasks.default: "light"`). Work is recorded with
  `cckit task new`, listed with `cckit task list`, started with `cckit task start <id>` and sent for
  review with `cckit task finish <id> "<summary>" --all`, which opens the pull request (`--all`
  includes the files created for the task; without it a new draft is left out).
  `cckit task run <id>` does the start, one unattended round behind the project's check
  (`tasks.check`) and the pull request in one step. The issue loop
  below applies only to work {{OWNER_NAME}} asks to track as a GitHub issue. `tasks/` is that list
  and `cckit task` keeps it: the "never maintain task lists in markdown" line does not cover it.
<!-- /IF:LIGHT_TASKS -->

## Roles

Every issue carries a `role:` label. Active roles for this project: {{ROLES_HUMAN}}.

The role determines which agent owns the work. Spawn that agent for the actual execution.

## Kinds

`task` · `plan` · `adr` · `scaffold` · `spike` — drives the branch prefix `<kind>/<N>-<slug>`.
Content kinds `post` · `campaign` · `brand` · `research` are labels only: the branch starts on
`task/` · `plan/` · `task/` · `spike/`.

## Priorities

`p1` (now / blocking) · `p2` (next) · `p3` (later).

## Milestones

{{MILESTONES_HUMAN}}

## The loop

1. `/kit-task-sync` — see the board, pick an unblocked issue
2. `/kit-task-start <N>` — isolated worktree + branch from the base, mark In Progress
3. Do the work (spawn the owning agent)
4. `/kit-task-pr <N>` — commit, push, open PR
5. `/kit-task-pr-merge` — squash-merge, back to `{{BASE_BRANCH}}`
6. `/kit-task-close <N>` — close issue<!-- IF:PLANS -->, archive plan if all deliverables merged<!-- /IF:PLANS -->

## Rules

- One PR per issue — no monster PRs. **Exception: a coupled migration/DDL chain ships as ONE PR (and ideally one issue)** — don't fragment a sequenced migration set into a PR-per-file. Split only for independent migrations or a step needing its own review gate (data backfill, RLS behavior change). `merge-safety.md` § 2 is the general form: any coupled chain, not only DDL.
- PR title = issue title · body includes `Closes #N`
- Labels + milestone inherited from the issue
- Never file an issue without confirming title + role + priority with {{OWNER_NAME}}
- Never create new label families on the fly — fail loudly if a kind/priority is unknown
