---
name: kit-effort-start
description: Start an effort — create the `effort/<N>-<slug>` integration branch + isolated worktree from the base branch and mark the parent issue In Progress on the board. Sub-issues later branch from this effort branch or commit directly on it.
when_to_use: After `/kit-effort-new`, to begin building an effort. The effort branch is the single integration branch for the whole effort — its sub-issues merge into it, and exactly one PR opens from it (`/kit-effort-pr`). See rules/effort-model.md.
---

# kit-effort-start

Plugin-direct skill — runs straight from `${CLAUDE_PLUGIN_ROOT}` (no per-project `scripts/` checkout
needed). Helpers are sourced from the plugin; repo state (`gh`, `git`, the board) is the project
you're standing in. Respects `KIT_BASE_BRANCH` (default `main`) so the same code serves any project.
Reads `.claude/kit.config.json` from the working directory.

## Inputs

| Field        | Required | Notes                                                          |
| ------------ | -------- | -------------------------------------------------------------- |
| Issue number | ✓        | The **parent** effort issue `N`                                |
| Slug         | optional | Short kebab-case suffix; defaults to a slug of the issue title |

> **One effort = one branch = one worktree** (effort-model.md). The branch is `effort/<N>-<slug>`
> and the worktree is `.claude/worktrees/effort+<N>-<slug>`. Sub-issues either commit directly on
> this branch (sequential — one commit per sub-issue, that commit's diff IS the sub's work record)
> or use their own file-disjoint `sub/<N><letter>-<slug>` worktrees off this branch and merge in.
> Exactly ONE PR opens from `effort/<N>` (`/kit-effort-pr`).

## Execution

```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/kit-config.sh" && load_kit_config
[[ "$KIT_PROJECTS_V2" == "true" ]] && { source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/gh-project.sh"; load_project_ids; }
BASE="${KIT_BASE_BRANCH:-main}"   # branch off the integration branch (override per project)

NUM=""; SLUG_OVERRIDE=""
for a in "$@"; do
  [[ -z "$NUM" ]] && NUM="$a" || SLUG_OVERRIDE="$a"
done
[[ -n "$NUM" ]] || { echo "✗ kit-effort-start: parent issue number required"; exit 1; }

META=$(gh issue view "$NUM" --repo "$KIT_REPO" --json title,labels,projectItems)
TITLE=$(echo "$META" | jq -r .title)

if [[ -n "$SLUG_OVERRIDE" ]]; then SLUG="$SLUG_OVERRIDE"; else
  SLUG=$(echo "$TITLE" | sed -E 's/^\[[^]]+\][[:space:]]*//' \
    | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-|-$//g' | cut -c1-40)
fi

# The integration branch is ALWAYS effort/<N>-<slug> (branch-naming.md), regardless of the
# parent's kind:* label. The worktree dir still encodes #N so kit-gc protects it while #N is open.
BRANCH="effort/$NUM-$SLUG"
WT_DIR=".claude/worktrees/effort+${NUM}-${SLUG}"

git fetch origin "$BASE" --quiet
if git worktree list --porcelain | grep -q "/effort+${NUM}-${SLUG}$"; then
  echo "✓ Worktree already exists: $WT_DIR (branch $BRANCH)"
else
  git worktree add -B "$BRANCH" "$WT_DIR" "origin/$BASE"
fi

if [[ "$KIT_PROJECTS_V2" == "true" ]]; then
  ITEM_ID=$(echo "$META" | jq -r --arg t "$KIT_PROJECT_TITLE" '.projectItems[]? | select(.title==$t) | .id')
  [[ -n "$ITEM_ID" ]] && project_set_single_select "$ITEM_ID" "$STATUS_FIELD_ID" "$STATUS_OPT_IN_PROGRESS"
fi

echo "→ cd $WT_DIR   # ALL effort work happens here; sub-issues merge into $BRANCH"
echo "✓ Worktree $WT_DIR on branch $BRANCH (from $BASE) — effort #$NUM In Progress"
echo "  Next: build the sub-issues, then /kit-effort-pr $NUM"
```

## Output

- Worktree path + `effort/<N>-<slug>` branch — **work continues inside the worktree** (`cd $WT_DIR`)
- Parent issue #N now In Progress on the board (if Projects v2 is on)
- Reminder that exactly one PR opens from this branch (`/kit-effort-pr <N>`)

## Rules

- The integration branch is **always** `effort/<N>-<slug>` (branch-naming.md, effort-model.md) —
  never `task/` or `feat/` for the parent.
- Branch from the base branch (`KIT_BASE_BRANCH`) only — never from a feature branch.
- **Worktree always** — one branch per worktree, never share a checkout. The `effort+<N>-<slug>`
  worktree-dir name encodes #N so `kit-gc` won't wipe it while the issue is open.
- Sub-issue branches are `sub/<N><letter>-<slug>` off THIS branch and **never open their own PR to
  the base branch** — they merge into `effort/<N>`.
- Don't re-run for the parent if its worktree already exists — the skill reuses it.
