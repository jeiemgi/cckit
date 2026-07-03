---
name: kit-effort-close
description: Close an effort in ONE op — snapshot each sub-issue's diff BEFORE squash (work record), capture/judge/sync effort metrics, squash-merge the effort PR, close the parent + ALL native sub-issues, set the board Status=Done for each, garbage-collect the worktree/branch, run the optional knowledge-ingest hook, and finish with the kit-sync drift check.
when_to_use: When the effort PR has been reviewed and is ready to land. This is the single close op for the effort lifecycle (effort-model.md) — board + record state are correct by construction. Replaces the separate merge / close / mark-done / gc steps.
---

# kit-effort-close

Plugin-direct skill — runs straight from `${CLAUDE_PLUGIN_ROOT}` (no per-project `scripts/`
checkout needed). It is a **thin caller** of the single close implementation `effort_close`
(`scripts/lib/effort-ops.sh`) — the exact function `cckit effort close <N>` runs — so the skill
and the verb close an effort identically (#148, the #121 single-implementation precedent). No
close logic is re-authored inline (kit-engine-boundary #1/#2). Respects `KIT_BASE_BRANCH`
(default `main`) and the `KIT_PROJECTS_V2` board toggle.

The effort lifecycle's terminal op. Board state, issue state, and the work record are correct
**by construction** — the core op owns them, in this order:

1. **Snapshot sub-diffs BEFORE squash** (squash destroys the per-sub-issue commit pairs that ARE
   the work record — effort-model.md "Trace hard rules"), with a **refuse-squash-without-trace**
   backstop (`KIT_FORCE=1` overrides).
2. **Capture effort metrics** pre-squash (telemetry: live-branch diff + commit signals).
3. **Squash-merge** the effort PR.
4. **Judge + sync** the metrics (reads the durable trace dir; no-ops when the engine is off).
5. **Close the parent + ALL native sub-issues** and set the **board Status=Done** for each
   (guarded — a no-op when Projects v2 is off).
6. **GC**: base branch checked out + pulled in the main checkout, effort worktree removed,
   local branch deleted, pruned (the remote branch is deleted by the merge).
7. **Knowledge-ingest hook** (optional, config-gated via `effort.knowledgeIngestHook`).
8. **Kit-sync drift check** — advisory warning when the effort touched kit-managed files that
   belong upstream (/kit-contribute).

## Preconditions

1. The effort PR exists, is reviewed, not in draft, and is mergeable (or rebaseable).
2. You are on the `effort/<N>-<slug>` branch (its worktree), working tree clean.

If not, abort and route to `/kit-effort-pr` first.

## Inputs

| Field        | Required | Notes                                                   |
| ------------ | -------- | ------------------------------------------------------- |
| Issue number | optional | Parent #N or slug — derived from `effort/<N>-<slug>` if omitted |

## Execution

This skill is a **thin caller** of `effort_close` (`scripts/lib/effort-ops.sh`) — the SAME
function `cckit effort close` runs. The core owns the pre-squash snapshot + trace backstop,
telemetry capture/judge/sync, the squash-merge, issue closes, board Done, GC, the
knowledge-ingest hook, and the kit-sync drift check. There is no second implementation here.

The core handles both effort styles (#164): run from the `effort/<N>-…` branch it squash-merges
the integration PR; run from anywhere else with an explicit `#N`, and if no `effort/<N>` branch
exists anywhere (a **wave-driven** effort — subs merged as individual task PRs), it verifies every
sub is closed with a merged PR, traces from the merged PR diffs, and runs the same close tail.

```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/kit-config.sh" && load_kit_config
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/effort.sh"
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/effort-ops.sh"   # effort_close — the single close op

BRANCH=$(git rev-parse --abbrev-ref HEAD)

# Resolve the parent #N (accepts a slug too — effort_slug_resolve); default to the branch.
NUM="${INPUT_NUM:-}"
[[ -z "$NUM" ]] && NUM=$(effort_branch_num "$BRANCH")
[[ -z "$NUM" ]] && { echo "✗ Not on an effort branch (effort/<N>-<slug>) and no #N passed"; exit 1; }

if [[ -n "$(git status --porcelain)" ]]; then
  echo "✗ Working tree dirty — commit via /kit-effort-pr first"; exit 1
fi

# The single close op — identical to `cckit effort close $NUM`.
effort_close "$NUM"
```

> The block above is intentionally short: all close logic lives in `effort_close`. If you need to
> change what a close does (trace, telemetry, board, GC, hooks, drift check), change the core —
> both the skill and the verb move together.

## Output

- Pre-squash trace dir (`<git-common-dir>/traces/effort-<N>/` + `index.jsonl`) + captured metrics
- PR squash-merged; parent + all native sub-issues closed
- Board Status=Done for parent + every sub (if Projects v2 is on)
- Main checkout on the base branch, up to date; effort worktree + local/remote branch removed and pruned
- Knowledge-ingest hook ran (if configured); a kit-sync warning if the effort touched kit-managed files

## Rules

- **One close implementation** — `effort_close` in `scripts/lib/effort-ops.sh`. Never re-author
  merge/close/board/GC steps inline here (#148; the #121 PR-title precedent).
- **Snapshot BEFORE squash — absolute.** Squash destroys the per-sub-issue commit pairs that ARE
  the per-unit work record; the core refuses to squash when no trace was captured (`KIT_FORCE=1`
  overrides). The trace lives under the **shared git-common-dir** so it survives the worktree prune.
- **One op owns board + issue + record state** — never rely on a separate, skippable "mark done"
  (effort-model.md). All subs go Done in the core.
- recover-before-prune (branch-naming.md): never remove a worktree with a staged-but-uncommitted
  delta — the working tree must be clean (precondition) before this op proceeds.
- Scrub secrets from the trace if any commit diff could contain them (trace hygiene).
- Never force-push to trunk; never delete the default branch.
- **Heed the kit-sync warning:** a kit-managed change that isn't contributed upstream is a latent
  regression the next `/kit-update` can revert. Treat the warning as a to-do.
