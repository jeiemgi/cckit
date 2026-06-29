---
name: kit-task-start
description: Start work on a GitHub issue — branch from the base branch (optionally an isolated worktree associated with the issue), mark the issue In Progress on the board (if enabled), switch to the branch.
when_to_use: When beginning work on a tracked issue. Always run before editing files. Replaces ad-hoc `git checkout -b`.
---

# kit-task-start

Plugin-direct skill — runs straight from `${CLAUDE_PLUGIN_ROOT}` (no per-project `scripts/`
checkout needed). Helpers are sourced from the plugin; repo state (`gh`, `git`, the board) is
the project you're standing in. Reads `.claude/kit.config.json` from the working directory.

## Inputs

| Field        | Required | Notes                                                       |
| ------------ | -------- | ----------------------------------------------------------- |
| Issue number | ✓        | `123`                                                       |
| Slug         | optional | Short kebab suffix; defaults to a slug of the issue title   |
| `--worktree` | optional | Isolated worktree instead of switching the main tree. **Required for parallel / sub-agent work.** Dir `<kind>+<N>-<slug>` encodes issue **#N**, so `kit-gc` won't wipe it while the issue is open. |

Read the issue to derive the **kind** label — the branch prefix matches it.

## Execution

```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/kit-config.sh" && load_kit_config
[[ "$KIT_PROJECTS_V2" == "true" ]] && { source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/gh-project.sh"; load_project_ids; }
BASE="${KIT_BASE_BRANCH:-main}"   # branch off the integration branch (override per project)

NUM=""; SLUG_OVERRIDE=""; WORKTREE=0
for a in "$@"; do
  case "$a" in
    --worktree) WORKTREE=1 ;;
    *) [[ -z "$NUM" ]] && NUM="$a" || SLUG_OVERRIDE="$a" ;;
  esac
done
META=$(gh issue view "$NUM" --repo "$KIT_REPO" --json title,labels,projectItems)
TITLE=$(echo "$META" | jq -r .title)
KIND=$(echo "$META" | jq -r '.labels[].name' | grep '^kind:' | head -1 | cut -d: -f2)
[[ -z "$KIND" ]] && KIND="task"

if [[ -n "$SLUG_OVERRIDE" ]]; then SLUG="$SLUG_OVERRIDE"; else
  SLUG=$(echo "$TITLE" | sed -E 's/^\[[^]]+\][[:space:]]*//' \
    | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-|-$//g' | cut -c1-40)
fi
BRANCH="$KIND/$NUM-$SLUG"

git fetch origin "$BASE" --quiet
if [[ "$WORKTREE" -eq 1 ]]; then
  # Worktree dir encodes the issue: <kind>+<N>-<slug> -> kit-gc protects it while #N is open.
  WT_DIR=".claude/worktrees/${KIND}+${NUM}-${SLUG}"
  if git worktree list --porcelain | grep -q "/${KIND}+${NUM}-${SLUG}$"; then
    echo "✓ Worktree already exists: $WT_DIR (branch $BRANCH)"
  else
    git worktree add -B "$BRANCH" "$WT_DIR" "origin/$BASE"
  fi
  echo "→ cd $WT_DIR   # work happens here; one branch per worktree"
else
  [[ -n "$(git status --porcelain)" ]] && { echo "✗ Working tree not clean — or use --worktree."; exit 1; }
  git checkout -B "$BRANCH" "origin/$BASE"
fi

if [[ "$KIT_PROJECTS_V2" == "true" ]]; then
  ITEM_ID=$(echo "$META" | jq -r --arg t "$KIT_PROJECT_TITLE" '.projectItems[]? | select(.title==$t) | .id')
  [[ -n "$ITEM_ID" ]] && project_set_single_select "$ITEM_ID" "$STATUS_FIELD_ID" "$STATUS_OPT_IN_PROGRESS"
fi

echo "✓ Branch $BRANCH (from $BASE) — issue #$NUM In Progress"
```

## Rules

- Never start from a non-base branch (trunk-based) · never start with a dirty tree (in-place mode) — or use `--worktree`
- **Parallel / sub-agent work MUST use `--worktree`** — one branch per worktree, never share a checkout. The worktree↔issue association keeps `kit-gc` from wiping in-progress work.
- If the issue has no `role:` label, fail loudly and ask for triage
- Never skip the board status update when Projects v2 is enabled
