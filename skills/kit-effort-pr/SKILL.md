---
name: kit-effort-pr
description: Open the ONE pull request for an effort — `effort/<N>` → base branch — with a rich human-facing review body plus a `## For agents` section listing the file paths/entry points. Title `[Role] [#N] <title>`. Inherits labels + milestone from the parent issue and moves it to In Review on the board.
when_to_use: When an effort branch is ready for review (all its sub-issues built + merged into the effort branch). One effort = one PR (effort-model.md) — never open per-sub PRs to the base branch. Mirrors `kit-task-pr` for the effort lifecycle.
---

# kit-effort-pr

Plugin-direct skill — runs straight from `${CLAUDE_PLUGIN_ROOT}` (no per-project `scripts/` checkout
needed). Helpers (config, role identity, board) are sourced from the plugin (kit-engine-boundary
#1/#2). Respects `KIT_BASE_BRANCH` (default `main`) and the `KIT_PROJECTS_V2` board toggle.

Opens the **single** PR for an effort. The PR carries the human-facing review write-up + a
`## For agents` section (retrieval context / the work record). The parent issue holds the plan;
this PR is where humans review the result. The title carries `[#N]` (the effort id) — mandatory
(effort-model.md, effort-id taxonomy).

## Inputs

| Field          | Required | Notes                                                       |
| -------------- | -------- | ----------------------------------------------------------- |
| Issue number   | optional | The **parent** effort #N — derived from `effort/<N>-<slug>` |
| Summary        | ✓        | The human review write-up (what changed + why)              |
| For agents     | ✓        | File paths / entry points — the PR's `## For agents` block  |
| Commit message | optional | Defaults to `<role>: <issue title>` for any pending changes |

## Execution

```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/kit-config.sh" && load_kit_config
[[ "$KIT_PROJECTS_V2" == "true" ]] && { source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/gh-project.sh"; load_project_ids; }
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/role-identity.sh" 2>/dev/null || true
BASE="${KIT_BASE_BRANCH:-main}"

# 1. Parse the parent effort number from the branch (effort/<N>-<slug>).
BRANCH=$(git rev-parse --abbrev-ref HEAD)
NUM="${INPUT_NUM:-}"
[[ -z "$NUM" ]] && NUM=$(echo "$BRANCH" | sed -nE 's#^effort/([0-9]+)-.*#\1#p')
[[ -z "$NUM" ]] && { echo "✗ Branch $BRANCH is not an effort branch (effort/<N>-<slug>)"; exit 1; }

# 2. Pull parent issue metadata.
META=$(gh issue view "$NUM" --repo "$KIT_REPO" --json title,labels,milestone)
TITLE=$(echo "$META" | jq -r .title)
LABELS=$(echo "$META" | jq -r '[.labels[].name] | join(",")')
MILESTONE=$(echo "$META" | jq -r '.milestone.title // ""')
ROLE=$(echo "$LABELS" | tr ',' '\n' | grep '^role:' | head -1 | cut -d: -f2)
ROLE_DISPLAY=$(role_display "$ROLE" 2>/dev/null || echo ""); [[ -z "$ROLE_DISPLAY" ]] && ROLE_DISPLAY="Tech Lead"

# 3. Commit any pending changes — role identity is a Co-authored-by TRAILER, never the git author
#    (some deploy providers refuse commits whose author email matches no account).
COMMIT_MSG="${COMMIT_MSG:-$ROLE: $TITLE}"
if [[ -n "$(git status --porcelain)" ]]; then
  git add -A
  AUTHOR=$(role_git_author "$ROLE" 2>/dev/null || echo "")
  if [[ -n "$AUTHOR" ]]; then
    git commit -m "$COMMIT_MSG" -m "Co-authored-by: ${AUTHOR%%|*} <${AUTHOR##*|}>"
  else
    git commit -m "$COMMIT_MSG"
  fi
fi

# 4. Push.
git push -u origin "$BRANCH"

# 5. Compose the PR body — rich human review + the agent-facing retrieval block.
PR_BODY=$(cat <<EOF
## For the orchestrator

Effort #$NUM — one PR for the whole effort. Review: the summary below + the diff.

Closes #$NUM

## Summary

$SUMMARY

## For agents

$FOR_AGENTS

## Verification

- [ ] Each sub-issue change is present in the diff
- [ ] No unrelated files in the diff
- [ ] Labels + milestone match the parent issue
- [ ] Local lint/typecheck pass

$(role_signature "$ROLE" 2>/dev/null || true)
EOF
)

# 6. Create the PR. Title: [Role] [#N] <title> — the [#N] effort id is mandatory.
URL=$(gh pr create --repo "$KIT_REPO" \
  --base "$BASE" \
  --head "$BRANCH" \
  --title "[$ROLE_DISPLAY] [#$NUM] $TITLE" \
  --body "$PR_BODY" \
  ${LABELS:+--label "$LABELS"} \
  ${MILESTONE:+--milestone "$MILESTONE"} \
  --assignee "@me")
echo "✓ $URL"

# 7. Board (if Projects v2): add the PR (In Review) + inherit Role; move the parent issue to In Review.
if [[ "$KIT_PROJECTS_V2" == "true" ]]; then
  PR_NUM=$(basename "$URL")
  PR_NODE=$(gh api "repos/$KIT_REPO/pulls/$PR_NUM" --jq .node_id)
  PR_ITEM=$(project_add_item "$PR_NODE" 2>/dev/null || echo "")
  if [[ -n "$PR_ITEM" ]]; then
    ROLE_OPT=$(role_option_id "$ROLE" 2>/dev/null || echo "")
    [[ -n "$ROLE_OPT" ]] && project_set_single_select "$PR_ITEM" "$ROLE_FIELD_ID" "$ROLE_OPT"
    project_set_single_select "$PR_ITEM" "$STATUS_FIELD_ID" "$STATUS_OPT_IN_REVIEW"
  fi
  # Parent issue → In Review (the finder paginates the whole board, not just the first page).
  PARENT_ITEM=$(project_find_item_by_issue "$NUM")
  [[ -n "$PARENT_ITEM" ]] && project_set_single_select "$PARENT_ITEM" "$STATUS_FIELD_ID" "$STATUS_OPT_IN_REVIEW"
fi

echo "  Next: review, then /kit-effort-close $NUM"
```

## Output

- The single effort PR URL (title `[Role] [#N] <title>`)
- PR + parent issue both at In Review on the board (if Projects v2 is on)
- Suggested next: `/kit-effort-close <N>`

## Rules

- **ONE PR per effort** — `effort/<N>` → base branch. Never open a PR from a `sub/<N><letter>`
  branch to the base; sub-issues merge into the effort branch first (effort-model.md).
- The title MUST carry `[#N]` (the effort id) — a PR title without it is a review blocker
  (effort-model.md, effort-id taxonomy).
- The body MUST include both a human `## Summary` and a `## For agents` (file paths) — the latter is
  retrieval context + part of the work record.
- `Closes #$NUM` closes the **parent** on merge; the sub-issues are closed by `/kit-effort-close`
  (so their pre-squash diffs are snapshotted first).
- Never invent a Summary or For-agents block — ask if missing.
- Labels + milestone mirror the parent issue; never strip them.
- Never push to a release branch directly.
