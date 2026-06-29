---
name: kit-task-pr-merge
description: Squash-merge the open PR for the current branch, switch to the base branch, and pull. Auto-rebases onto the base if conflicts are detected.
when_to_use: When work on an issue branch is ready to land. Always run after `/kit-task-pr`.
---

# kit-task-pr-merge

Plugin-direct skill — thin caller over the ONE canonical home
`${CLAUDE_PLUGIN_ROOT}/scripts/lib/kit-task-ops.sh` (`kto_task_pr_merge`). The verb logic lives
there, never inline here (kit-engine-boundary #1/#2). The op respects `KIT_BASE_BRANCH` (default
`develop`) and closes the PR's linked issues (native auto-close only fires on the default branch).

## Inputs

| Field     | Required | Notes                                          |
| --------- | -------- | ---------------------------------------------- |
| PR number | optional | Defaults to the open PR for the current branch |

## Execution

```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/kit-config.sh" && load_kit_config
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/role-identity.sh"
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/gh-project.sh"
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/kit-task-ops.sh"

kto_task_pr_merge            # open PR for the current branch
# kto_task_pr_merge 845      # an explicit PR number
```

After it returns on the base branch, run the kit-sync drift check (advisory; never blocks):

```bash
MAIN_WT=$(git worktree list --porcelain | awk '/^worktree /{print $2; exit}')
KIT_TOUCHED=$(git -C "$MAIN_WT" show --name-only --pretty=format: HEAD 2>/dev/null \
  | grep -E '^(scripts/(lib/|kit$|kit-)|\.claude/(skills|rules|hooks|lib|agents)/)' | sort -u || true)
if [[ -n "$KIT_TOUCHED" ]]; then
  echo ""
  echo "⚠ kit-sync: this change touched kit-managed files — review for upstream (/kit-contribute):"
  printf '   %s\n' $KIT_TOUCHED
  echo "   kit ⇄ project must stay in sync; an un-upstreamed change can be clobbered by /kit-update."
fi
```

## Rules

- Never merge a DRAFT PR — undraft first
- Never force-push to the base branch
- If rebase conflicts can't auto-resolve, the op aborts cleanly and surfaces the conflicting files
- If merge fails for a non-conflict reason (failing checks), the op reports verbatim and does not retry
- The op always ends on the base branch with a clean pull on success, and always cleans up the merged branch + worktree
- Never delete a branch that still has an open PR or unpushed commits not on the base branch's remote
