---
name: kit-effort-start
description: Start an effort — thin caller of `cckit effort start <N>`. Creates the `effort/<N>-<slug>` integration branch + isolated bootstrapped worktree from the base branch, then marks the parent issue In Progress on the board. Enforces the effort WIP limit (`effort.wipLimit`, default 2) — a new effort is refused, before anything is written, while that many are already in progress; `--force` starts anyway. Sub-issues later branch from this effort branch or commit directly on it.
when_to_use: After `/kit-effort-new`, to begin building an effort. The effort branch is the single integration branch for the whole effort — its sub-issues merge into it, and exactly one PR opens from it (`/kit-effort-pr`). See rules/effort-model.md.
---

# kit-effort-start

Thin caller over the ONE canonical effort-start mechanic: the `cckit effort start` verb →
`effort_start` (`${CLAUDE_PLUGIN_ROOT}/scripts/lib/effort-ops.sh`). The verb logic lives there,
never inline here (kit-engine-boundary #1/#2 — same single-implementation principle as the PR
title composer, #121). The dispatcher loads the project config first (#151), so `KIT_REPO` /
`KIT_BASE_BRANCH` come from `.claude/kit.config.json` of the project you're standing in. The verb
owns ALL of the mechanics:

- resolving `<N|slug>` to the parent effort issue (slug handles work too)
- the **WIP limit**: refusing a NEW effort once `effort.wipLimit` (default 2) are already in
  progress — see below
- fresh fetch of the base branch + branch `effort/<N>-<slug>` — always `effort/`, regardless of
  the parent's `kind:` label (branch-naming.md)
- the isolated worktree at `.claude/worktrees/effort+<N>-<slug>` (reused if the branch already
  exists; the dir name encodes #N so `kit-gc` won't wipe it while the issue is open)
- **bootstrap** (`wt_bootstrap`): copies gitignored `.env.local*` + project ids, assigns a
  per-worktree dev PORT, installs deps **at the selected targets**, in this
  precedence: `worktree.installPaths` if set (those dirs only, installed whether or not each one
  declares dependencies; `[]` = nothing), else the root *only when* its manifest declares
  dependencies or it is a workspace root *with at least one member*, else
  nothing — a dependency-free root never gets a stray empty `pnpm-lock.yaml`, and an `installPaths`
  entry that escapes the worktree is refused. `KIT_WT_INSTALL=0` opts out entirely
- the live-session **collision guard**: refuses to disturb a worktree a live session is sitting in

## Inputs

| Field        | Required | Notes                                                          |
| ------------ | -------- | -------------------------------------------------------------- |
| Issue number | ✓        | The **parent** effort issue `N` (or its slug handle)           |
| Slug         | optional | Short kebab-case suffix; defaults to a slug of the issue title |
| `--force`    | optional | Start past the WIP limit (`KIT_FORCE=1` does the same)          |

## The WIP limit

The verb refuses to start a **new** effort once `effort.wipLimit` (default **2**) are already in
progress. **In progress** = an `effort/<N>-<slug>` branch exists, local head **or** remote-tracking
ref — the same ref scan the slug resolver uses; the verb creates that branch and `effort close`
deletes it. The board Status is NOT the signal (the board step below is additive and skipped when
Projects v2 is off).

- **At** the limit refuses; only strictly under it starts. `0` freezes new efforts.
- Re-running the verb on an effort already in progress is never gated — it adds no WIP.
- The check runs before the fetch/branch/worktree/bootstrap, so a refusal writes **nothing**: no
  branch, no worktree, no board change, no GitHub call.
- Do not paper over a refusal. Report it and let the human decide: close an effort
  (`/kit-effort-close`), or re-run with `--force`. Only pass `--force` when the human asked for it.
- `EFFORT_WIP_LIMIT` overrides the configured limit for one invocation; a configured value that is
  not a non-negative integer is ignored with a warning and the default `2` is used.
- `cckit start <issue>` (a plain task worktree, `/kit-task-start`) has **no** WIP limit.

> **One effort = one branch = one worktree** (effort-model.md). Sub-issues either commit directly
> on this branch (sequential — one commit per sub-issue, that commit's diff IS the sub's work
> record) or use their own file-disjoint `sub/<N><letter>-<slug>` worktrees off this branch and
> merge in. Exactly ONE PR opens from `effort/<N>` (`/kit-effort-pr`).

## Execution

```bash
cckit effort start <N>     # or: cckit effort start <N> <slug-override>
cckit effort start --force <N>   # only when the human asked to start past the WIP limit
# cckit not on PATH? "${CLAUDE_PLUGIN_ROOT}/bin/cckit" effort start <N>
```

A WIP-limit refusal exits **1** and prints what is in progress. Nothing was created — surface the
message, do not retry with `--force` on your own.

The last stdout line is machine-readable — `<worktree-path>|<branch>|<parent-issue>` — then ALL
effort work continues **inside the worktree**:

```bash
cd <worktree-path>         # sub-issues merge into effort/<N>-<slug>
```

### Board step (additive — the verb does not touch the board)

Mark the parent effort In Progress when Projects v2 is enabled:

```bash
NUM=<parent-issue>   # third field of the verb's machine-readable line
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/kit-config.sh" && load_kit_config
if [[ "$KIT_PROJECTS_V2" == "true" ]]; then
  source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/gh-project.sh"; load_project_ids
  ITEM_ID=$(project_find_item_by_issue "$NUM")
  [[ -n "$ITEM_ID" ]] && project_set_single_select "$ITEM_ID" "$STATUS_FIELD_ID" "$STATUS_OPT_IN_PROGRESS"
fi
```

## Output

- Worktree path + `effort/<N>-<slug>` branch — **work continues inside the worktree**
- Parent issue #N now In Progress on the board (if Projects v2 is on)
- Reminder that exactly one PR opens from this branch (`/kit-effort-pr <N>`)

## Rules

- **Engine boundary** — the start mechanic lives in `effort_start`; this skill only runs the verb
  and does the board step. Never re-implement `git worktree add` / bootstrap / guards here.
- The integration branch is **always** `effort/<N>-<slug>` (branch-naming.md, effort-model.md) —
  never `task/` or `feat/` for the parent.
- Branch from the base branch (`KIT_BASE_BRANCH`) only — never from a feature branch; the verb
  enforces this.
- **Worktree always** — one branch per worktree, never share a checkout.
- Sub-issue branches are `sub/<N><letter>-<slug>` off THIS branch and **never open their own PR to
  the base branch** — they merge into `effort/<N>`.
- Safe to re-run for the parent: the verb reuses an existing branch/worktree, refuses to
  disturb one a live session owns, and never applies the WIP limit to an effort already in progress.
- **One effort at a time (within the limit)** — the WIP limit exists so efforts finish. When it
  fires, close something rather than forcing past it.
