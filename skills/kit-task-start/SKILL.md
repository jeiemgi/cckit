---
name: kit-task-start
description: Start work on a GitHub issue — thin caller of `cckit start <N>`. Creates an isolated, bootstrapped worktree + `<kind>/<N>-<slug>` branch from the base branch and marks the issue In Progress on the board (if enabled). Worktree-first — there is no in-place mode.
when_to_use: When beginning work on a tracked issue. Always run before editing files. Replaces ad-hoc `git checkout -b` and hand-rolled `git worktree add`.
---

# kit-task-start

Thin caller over the ONE canonical start mechanic: the `cckit start` verb → `wt_start`
(`${CLAUDE_PLUGIN_ROOT}/scripts/lib/worktree-start.sh`). The verb logic lives there, never inline
here (kit-engine-boundary #1/#2 — same single-implementation principle as the PR title composer,
#121). The verb owns ALL of the mechanics:

- fresh fetch of the base branch (`KIT_BASE_BRANCH`, default `main`) + branch `<kind>/<N>-<slug>`
  (kind derived from the issue's `kind:` label)
- the isolated worktree at `.claude/worktrees/<kind>+<N>-<slug>` (reused if it already exists;
  the dir name encodes issue #N so `kit-gc` won't wipe it while the issue is open)
- **bootstrap** (`wt_bootstrap`): copies gitignored `.env.local*` + project ids into the worktree,
  assigns a per-worktree dev PORT, installs deps (`KIT_WT_INSTALL=0` opts out)
- the **claim precheck** (#124): warns when the issue is already In Progress on the board —
  another session may own it
- the live-session **collision guard**: never disturbs a worktree a live session is sitting in
- the board update: issue → In Progress (when Projects v2 is enabled)

## Inputs

| Field        | Required | Notes                                                     |
| ------------ | -------- | --------------------------------------------------------- |
| Issue number | ✓        | `123`                                                     |
| Slug         | optional | Short kebab suffix; defaults to a slug of the issue title |

**Worktree-first, always.** Every start gets its own isolated worktree — one branch per worktree,
never a shared checkout. This is what makes parallel / sub-agent work safe and keeps a read-only
base checkout untouched.

## Execution

```bash
cckit start <N>            # or: cckit start <N> <slug-override>
# cckit not on PATH? "${CLAUDE_PLUGIN_ROOT}/bin/cckit" start <N>
```

The last stdout line is machine-readable — `<worktree-path>|<branch>|<issue-number>` — then work
continues **inside the worktree**:

```bash
cd <worktree-path>         # one branch per worktree; never edit the main checkout
```

## Output

- Worktree path + `<kind>/<N>-<slug>` branch (from the base branch) — work happens in the worktree
- Issue #N In Progress on the board (when Projects v2 is on)

## Rules

- **Engine boundary** — the start mechanic lives in `wt_start`; this skill only runs the verb.
  Never re-implement `git worktree add` / `git checkout -B` / bootstrap / board steps here.
- Worktree-first: parallel / sub-agent work MUST each get their own worktree via the verb —
  never share a checkout, never fall back to an in-place branch switch.
- Never start from a non-base branch (trunk-based) — the verb always branches from a fresh
  `origin/<base>`.
- If the issue has no `role:` label, fail loudly and ask for triage before starting.
- Heed the claim-precheck warning: if the verb reports the issue is already In Progress, confirm
  no other session owns it before continuing.
