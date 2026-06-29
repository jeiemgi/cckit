---
name: kit-effort-close
description: Close an effort in ONE op — snapshot each sub-issue's diff BEFORE squash (work record), squash-merge the effort PR, close the parent + ALL native sub-issues, set the board Status=Done for the parent and every sub, then garbage-collect (switch to the base branch, pull, remove the effort worktree, delete local+remote branch, prune). Finally, flag any kit-managed files the effort touched for upstream contribution.
when_to_use: When the effort PR has been reviewed and is ready to land. This is the single close op for the effort lifecycle (effort-model.md) — board + record state are correct by construction. Replaces the separate merge / close / mark-done / gc steps.
---

# kit-effort-close

Plugin-direct skill — runs straight from `${CLAUDE_PLUGIN_ROOT}` (no per-project `scripts/` checkout
needed). The verb logic (`effort_branch_num`, `effort_snapshot_subs`) lives in
`scripts/lib/effort.sh`, never re-authored inline (kit-engine-boundary #1/#2). Respects
`KIT_BASE_BRANCH` (default `main`) and the `KIT_PROJECTS_V2` board toggle.

The effort lifecycle's terminal op. Board state, issue state, and the work record are correct
**by construction** — this op owns them. Order matters: **snapshot before squash** (squash destroys
the per-sub-issue commit pairs that ARE the per-unit work record — effort-model.md "Trace hard rules").

## Preconditions

1. The effort PR exists, is reviewed, not in draft, and is mergeable (or rebaseable).
2. You are on the `effort/<N>-<slug>` branch (its worktree), working tree clean.

If not, abort and route to `/kit-effort-pr` first.

## Inputs

| Field        | Required | Notes                                                   |
| ------------ | -------- | ------------------------------------------------------- |
| Issue number | optional | Parent #N — derived from `effort/<N>-<slug>` if omitted |
| PR number    | optional | Defaults to the open PR for the effort branch           |

## Execution

```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/kit-config.sh" && load_kit_config
[[ "$KIT_PROJECTS_V2" == "true" ]] && { source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/gh-project.sh"; load_project_ids; }
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/effort.sh"
BASE="${KIT_BASE_BRANCH:-main}"

BRANCH=$(git rev-parse --abbrev-ref HEAD)

# 0. Resolve parent #N + the effort PR.
NUM="${INPUT_NUM:-}"
[[ -z "$NUM" ]] && NUM=$(effort_branch_num "$BRANCH")
[[ -z "$NUM" ]] && { echo "✗ Not on an effort branch (effort/<N>-<slug>) and no #N passed"; exit 1; }

if [[ -n "$(git status --porcelain)" ]]; then
  echo "✗ Working tree dirty — commit via /kit-effort-pr first"; exit 1
fi

PR_NUM="${INPUT_PR:-}"
[[ -z "$PR_NUM" ]] && PR_NUM=$(gh pr list --repo "$KIT_REPO" --head "$BRANCH" --state open --json number --jq '.[0].number // empty')
[[ -z "$PR_NUM" ]] && { echo "✗ No open PR for $BRANCH — run /kit-effort-pr $NUM"; exit 1; }
echo "→ effort #$NUM · PR #$PR_NUM · branch $BRANCH"

# ── (a) SNAPSHOT SUB-DIFFS *BEFORE* SQUASH ───────────────────────────────────────────────
# Squash collapses the per-sub-issue commits; capture each commit's diff + its sub-issue pairing
# NOW, to a durable trace dir under the shared git-common-dir (survives the worktree prune below).
TRACE_DIR=$(effort_snapshot_subs "$NUM" "origin/$BASE")
echo "  trace: ${TRACE_DIR:-<none>}"

# ── (b) SQUASH-MERGE THE EFFORT PR ───────────────────────────────────────────────────────
MERGE_INFO=$(gh pr view "$PR_NUM" --repo "$KIT_REPO" --json mergeable,isDraft --jq '{m:.mergeable,d:.isDraft}')
[[ "$(echo "$MERGE_INFO" | jq -r .d)" == "true" ]] && { echo "✗ PR #$PR_NUM is a draft — undraft first"; exit 1; }
if [[ "$(echo "$MERGE_INFO" | jq -r .m)" == "CONFLICTING" ]]; then
  echo "→ Conflicts — rebasing onto $BASE..."
  git fetch origin "$BASE" && git rebase "origin/$BASE" \
    && git push --force-with-lease origin "$BRANCH" \
    || { echo "✗ Rebase conflicts need manual resolution"; git rebase --abort 2>/dev/null; exit 1; }
  sleep 3
fi
gh pr merge "$PR_NUM" --repo "$KIT_REPO" --squash || { echo "✗ Merge failed — see https://github.com/$KIT_REPO/pull/$PR_NUM"; exit 1; }
echo "✓ PR #$PR_NUM squash-merged"

# ── (c) CLOSE PARENT + ALL NATIVE SUB-ISSUES ─────────────────────────────────────────────
# Native sub-issues (GitHub parent/child). Collect them via GraphQL subIssues.
SUBS=$(gh api graphql -f query='
  query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){issue(number:$n){
    subIssues(first:50){nodes{number state}}}}}' \
  -F o="${KIT_REPO%/*}" -F r="${KIT_REPO#*/}" -F n="$NUM" \
  --jq '.data.repository.issue.subIssues.nodes[]?.number' 2>/dev/null)

# The parent auto-closes on merge to the default branch via `Closes #N`; ensure it, plus close every sub.
for N in $NUM $SUBS; do
  STATE=$(gh issue view "$N" --repo "$KIT_REPO" --json state --jq .state 2>/dev/null)
  if [[ "$STATE" == "OPEN" ]]; then
    gh issue close "$N" --repo "$KIT_REPO" \
      --comment "Closed on merge of effort PR #$PR_NUM (parent #$NUM) — /kit-effort-close." \
      && echo "✓ closed #$N"
  else
    echo "  #$N already ${STATE:-unknown} — skipped"
  fi
done

# ── (d) BOARD: STATUS=DONE FOR PARENT + ALL SUBS ─────────────────────────────────────────
# project_find_item_by_issue paginates the WHOLE board and fails loudly instead of returning empty.
if [[ "$KIT_PROJECTS_V2" == "true" ]]; then
  for N in $NUM $SUBS; do
    ITEM=$(project_find_item_by_issue "$N") || { echo "  ⚠ board lookup failed for #$N (see stderr)"; continue; }
    if [[ -n "$ITEM" ]]; then
      project_set_single_select "$ITEM" "$STATUS_FIELD_ID" "$STATUS_OPT_DONE" && echo "✓ board Done: #$N"
    else
      echo "  ⚠ #$N not on board — skipped"
    fi
  done
fi

# ── (e) GC: trunk + prune the effort worktree/branch ─────────────────────────────────────
WT=$(git worktree list --porcelain | awk -v b="refs/heads/$BRANCH" '/^worktree /{p=$2} /^branch /{if($2==b) print p}')
MAIN_WT=$(git worktree list --porcelain | awk '/^worktree /{print $2; exit}')
git -C "$MAIN_WT" checkout "$BASE" 2>/dev/null || git checkout "$BASE"
git -C "$MAIN_WT" pull origin "$BASE" 2>/dev/null || git pull origin "$BASE"
if [[ -n "$WT" && "$WT" != "$MAIN_WT" ]]; then
  git worktree remove "$WT" --force && echo "✓ removed worktree $WT"
fi
git branch -D "$BRANCH" 2>/dev/null && echo "✓ deleted local branch $BRANCH"
git push origin --delete "$BRANCH" 2>/dev/null && echo "✓ deleted remote branch $BRANCH" || echo "  (remote branch already gone)"
git worktree prune

# ── (f) KIT-SYNC DRIFT CHECK — kit ⇄ project stay in sync ─────────────────────────────────
# If this effort changed kit-managed files, they likely belong upstream (/kit-contribute) — a
# future /kit-update could otherwise clobber un-upstreamed fixes. Advisory; never blocks the close.
KIT_TOUCHED=$(git -C "$MAIN_WT" show --name-only --pretty=format: HEAD 2>/dev/null \
  | grep -E '^(scripts/(lib/|kit$|kit-)|\.claude/(skills|rules|hooks|lib|agents)/)' | sort -u || true)
if [[ -n "$KIT_TOUCHED" ]]; then
  echo ""
  echo "⚠ kit-sync: this effort changed kit-managed files — review for upstream (/kit-contribute):"
  printf '   %s\n' $KIT_TOUCHED
  echo "   kit ⇄ project must stay in sync; an un-upstreamed change can be clobbered by /kit-update."
fi

echo "✓ effort #$NUM closed — merged, parent+subs Done, trace at ${TRACE_DIR:-<none>}, worktree pruned"
```

## Output

- Pre-squash trace dir (`<git-common-dir>/traces/effort-<N>/` + `index.jsonl`)
- PR squash-merged; parent + all native sub-issues closed
- Board Status=Done for parent + every sub (if Projects v2 is on)
- On the base branch, up to date; effort worktree + local/remote branch removed and pruned
- A kit-sync warning if the effort touched kit-managed files

## Rules

- **Snapshot BEFORE squash — absolute** (step a). Squash destroys the per-sub-issue commit pairs
  that ARE the per-unit work record. Never reorder a/b. The trace lives under the **shared
  git-common-dir** so it survives the worktree prune in step e.
- **One op owns board + issue + record state** — never rely on a separate, skippable "mark done"
  (effort-model.md). All subs go Done here.
- Never merge a draft PR — abort with instructions to undraft.
- recover-before-prune (branch-naming.md): never remove a worktree with a staged-but-uncommitted
  delta — the working tree must be clean (precondition) before this op proceeds.
- Scrub secrets from the trace if any commit diff could contain them (trace hygiene).
- Never force-push to trunk; never delete the default branch.
- **Heed step (f):** a kit-managed change that isn't contributed upstream is a latent regression
  the next `/kit-update` can revert. Treat the warning as a to-do.
