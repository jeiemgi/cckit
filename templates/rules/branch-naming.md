# Branch & Merge Conventions

Canonical naming + merge-order rules so you're never confused about *what a branch is*, *what order PRs merge in*, or *which agent is touching what*.

## Branch name format

```
<kind>/<issue-number>-<slug>
```

- `<kind>` — one of the closed set below. No other prefixes.
- `<issue-number>` — the issue this branch closes. **Always required** for human work.
- `<slug>` — short kebab-case description (≤ 5 words).

### Closed set of kinds

| Kind       | For                                                | Typical risk |
| ---------- | -------------------------------------------------- | ------------ |
| `feat`     | New user-facing feature                            | med          |
| `fix`      | Bug fix                                            | low–med      |
| `task`     | Concrete chunk of work (no feature/bug label fits) | low–med      |
| `chore`    | Tooling, deps, config, housekeeping                | low–med      |
| `security` | Vulnerability fix or hardening                     | **high**     |
| `scaffold` | Repo/infra scaffolding                             | med          |
| `ci`       | CI/CD, workflows, automation                       | med          |
| `adr`      | Architecture Decision Record                       | low          |
| `spike`    | Time-boxed research (may be thrown away)           | low          |
| `plan`     | Plan/report deliverable                            | low          |

### Bot branches (do not create by hand)

| Pattern    | Who                  | Notes                                                        |
| ---------- | -------------------- | ------------------------------------------------------------ |
| `agent/*`  | Auto-Dev CI agent    | Label an issue `agent:auto` → it branches + opens a PR. Never merges. |
| `claude/*` | Claude GitHub Action | Created when an issue/PR mentions `@claude`.                 |

## Merge order

The integration branch is decided by, in priority:

1. **Declared dependencies first.** If PR B needs PR A, put `Depends on #A` in B's body. Land A before B.
2. **`risk:low` before `risk:high`.** Land cheap, safe, reviewed PRs first to shrink the conflict surface.
3. **Lockfile-touching PRs last, one at a time** (see below).
4. **Smaller before larger.** Big diffs rebase cleaner onto a moving target than the reverse.

**Effort relations & session-fit.** At the **effort** level (above PRs), cross-effort dependencies
are declared as a native GitHub `blocked_by` edge + a `## Relations` line (the board-visible chain) —
the analogue of the PR-level `Depends on #N` above. A `[Flow]` title tag + `flow:<flow>` label group
an effort's thread, and a `ctx:*` label drives `kit effort plan`'s session batching. Full spec:
`rules/effort-model.md` § *Title rule, flow tags, relations, session-fit*.

## The lockfile rule

Lockfiles (`pnpm-lock.yaml`, `package-lock.json`, …) and manifest config conflict on almost every parallel merge. So:

- **Merge at most one dependency-changing PR at a time**, then rebase the others.
- On a lockfile conflict: take the **base** branch's lockfile, then regenerate (`pnpm install` / `npm install`). Never hand-merge lockfile hunks.
- Keep a single block per config key (e.g. one `overrides:` in `pnpm-workspace.yaml`). A duplicate key is invalid YAML and breaks CI — a real, recurring incident.

## Parallel work — one worktree per agent (hard rule)

**Two agents in the same git checkout corrupt each other.** The working tree, index, and `HEAD` are a single unguarded shared resource: one agent's `mv`/`add`/`stage` is silently clobbered by another's `reset`/`checkout`/`stash`/`rebase`. Git has no locking for this.

- **One agent = one git worktree** (or a separate clone). Never two agents in the same directory.
- Prefer giving local sub-agents their own worktree.
- Remote CI agents (Auto-Dev) are isolated per runner — favor them for parallel fixes.
- Before editing shared files, check whether another agent is active.
- One PR per issue. No monster PRs (a `size:XL` label is a smell — split it).

## Optional: PR automation labels

If the project adopts the kit's PR-automation workflows, these labels are applied automatically:

| Label group | Applied by   | Meaning                                                  |
| ----------- | ------------ | -------------------------------------------------------- |
| `size:*`    | pr-labeler   | XS/S/M/L/XL by changed lines                             |
| `risk:*`    | pr-labeler   | low/med/high by diff (sensitive paths, deps, size)       |
| `blocked`   | pr-deps      | has an open `Depends on #N`                              |
| `hold`      | human        | opt-out — never auto-merge even if it qualifies          |

**GitHub gotcha:** `pull_request_target` / `workflow_run` / label-event workflows are read from the **default branch only**. If your automation lives on a non-default integration branch, trigger on `pull_request` (read from the PR base) instead — otherwise it silently never fires.

## Branch lifecycle & cleanup

One branch = one issue = one PR = **deleted on merge**. A branch is a short-lived container, not a place work lives.

- **No long-lived uncommitted work.** Don't let a working tree sit dirty across sessions. Commit + PR, or discard. A branch sitting many commits behind the base with uncommitted work can silently revert merged work on a bad rebase — exactly the class of problem this section exists to prevent.
- **Never work directly on the base branch (`main`/`develop`).** The `guard-base-branch-commit.sh` hook blocks commits there; start every change with `/kit-task-start <issue>` (it branches from a *fresh* base).
- **Delete on merge.** `/kit-task-pr-merge` removes the worktree and deletes the local + remote branch automatically. Never leave a merged branch or its worktree lingering.
- **One worktree per branch; remove it when its PR merges.** Parallel agents must use worktrees (never share a checkout).
- **Sweep on demand.** `/kit-task-gc` prunes merged branches + worktrees, surfaces orphan/unpushed commits and stale stashes, and flags issues whose PR merged but stayed open. Dry-run + confirm.
- The **SessionStart hygiene hook** (`.claude/hooks/repo-hygiene.sh`) surfaces all of the above at the start of every session so it never accumulates silently.

## Leverage GitHub automations (the enforced layer)

Local hooks + skills are **fast feedback**; the **durable, everyone-applies enforcement** belongs on GitHub. Move guardrails there as they mature — they then enforce for humans, CI agents (Auto-Dev), and the Claude Action alike, regardless of anyone's local setup.

- **Do first (1 toggle):** repo Settings → **"Automatically delete head branches"** — eliminates remote-branch buildup entirely.
- **Branch protection** on the base branch: require PR, required CI checks, linear history, no direct pushes.
- **Stale-branch / stale-PR Action** (scheduled) to flag/close abandoned branches + PRs.
- **Scheduled sweep** that flags "PR merged but issue still open" and "branch merged but not deleted".
- Extend any adopted `pr-labeler` / `pr-deps` / `pr-automerge` workflows as the enforcement surface.

Principle: **prefer migrating enforcement to GitHub** as it matures; keep only the genuinely local concerns (worktrees, stale base, dirty tree) in hooks.
