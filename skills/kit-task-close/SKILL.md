---
name: kit-task-close
description: Close a GitHub issue after its PR merged. Sets the board Status to Done (if enabled). If the issue is a plan parent, flips the plan status to Complete once all deliverables are merged (no archive folder — completed plans stay visible).
when_to_use: After a PR merges, to finalize the issue ledger. Most issues auto-close from PR `Closes #N` — use this for issues without a PR or to backfill the plan status.
---

# kit-task-close

Plugin-direct skill — thin caller over the ONE canonical home
`${CLAUDE_PLUGIN_ROOT}/scripts/lib/kit-task-ops.sh` (`kto_task_close`) for the issue-close +
board-Done git-mechanic (kit-engine-boundary #1/#2). The optional plan-badge flip stays here (it
edits a repo file → needs a worktree/PR), wrapping the op. The op respects the `KIT_PROJECTS_V2`
board toggle.

## Preconditions

1. Issue has a merged PR (`Closes #N`) OR an explicit no-PR reason in the closing comment
2. If a plan file is linked, the file exists

If neither holds, **abort** and route to `/kit-task-pr` first.

## Inputs

| Field        | Required | Notes                                          |
| ------------ | -------- | ---------------------------------------------- |
| Issue number | ✓        | `123` or full URL                              |
| Summary      | ✓        | 1–3 sentences — what was done, where it landed |

## Execution

```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/kit-config.sh" && load_kit_config
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/role-identity.sh"
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/gh-project.sh"
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/kit-task-ops.sh"

kto_task_close "$NUM" "$SUMMARY"
```

If a plan file is linked and all its deliverable PRs are merged, flip its status badge on a
worktree branch + PR (a repo change — never the main checkout; no archive folder, completed plans
stay visible):

```bash
if [[ "$KIT_PLANS_FORMAT" != "none" ]]; then
  PLAN_FILE=$(gh issue view "$NUM" --repo "$KIT_REPO" --json body --jq .body \
    | grep -oE "$KIT_PLANS_DIR/[a-zA-Z0-9_/-]+\.(md|mdx)" | head -1)
  if [[ -n "$PLAN_FILE" && -f "$PLAN_FILE" ]]; then
    ALL_MERGED=true
    for pr in $(awk '/^##+ .*[Dd]eliverables/{f=1; next} f && /^## /{exit} f' "$PLAN_FILE" | grep -oE '#[0-9]+' | grep -oE '[0-9]+' | sort -u); do
      [[ "$(gh pr view "$pr" --repo "$KIT_REPO" --json state -q .state 2>/dev/null)" != "MERGED" ]] && { ALL_MERGED=false; echo "⚠ PR #$pr not merged — plan stays Active"; break; }
    done
    if $ALL_MERGED; then
      sed -i '' -e 's/^status: .*/status: Complete/' -e 's/status="Active"/status="Complete"/' "$PLAN_FILE" 2>/dev/null \
        || sed -i -e 's/^status: .*/status: Complete/' -e 's/status="Active"/status="Complete"/' "$PLAN_FILE"
      echo "✓ Plan flipped to Complete: $PLAN_FILE — commit via /kit-task-pr"
    fi
  fi
fi
```

## Rules

- Never bypass the PR workflow — abort if no PR closed this issue and no explicit reason
- Never edit plan file content beyond the status flip · don't delete or move the plan file ·
  don't reopen the issue afterward
