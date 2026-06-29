---
name: kit-effort-new
description: Create an effort — a parent GitHub issue using the effort-model template (Goal / Scope / For agents / Verification) plus N native GitHub sub-issues linked via the sub-issues REST API, all added to the project board. The parent issue IS the plan.
when_to_use: When starting a new unit of work (a "plan"/effort) that decomposes into several sub-tasks. Replaces ad-hoc `gh issue create` for multi-part work. The effort splits into native sub-issues at scoping time; sequential subs commit on the effort branch, parallel subs use file-disjoint worktrees and merge in. See rules/effort-model.md.
---

# kit-effort-new

Plugin-direct skill — runs straight from `${CLAUDE_PLUGIN_ROOT}` (no per-project `scripts/` checkout
needed). Helpers are sourced from the plugin; the verb logic lives in `scripts/lib/effort.sh`
(`effort_link_sub`), never re-authored inline (kit-engine-boundary #1/#2). Repo + board config come
from `load_kit_config` (`$KIT_REPO`, `KIT_PROJECTS_V2`). Reads `.claude/kit.config.json` from the
working directory.

Creates the **parent issue** (the plan) + **N native sub-issues** for one effort. See
`rules/effort-model.md` for the model and the parent-issue template. GitHub is the single source of
truth — the parent issue IS the plan (no separate plan file).

## Inputs

| Field        | Required | Notes                                                                                       |
| ------------ | -------- | ------------------------------------------------------------------------------------------- |
| Title        | ✓        | The human **name only** (no `[Effort]`/number prefix) — the skill composes the board title. Concise, no jargon (`effort_title_lint`) |
| Role         | ✓        | `tech-lead` / `frontend` / … → `role:<role>` label + board Role field                       |
| Flow         | optional | Controlled-vocab flow (`EFFORT_FLOWS`) → `[Flow]` title tag + `flow:<flow>` label            |
| Goal         | ✓        | 1–2 lines — `## Goal`                                                                       |
| Scope        | ✓        | The sub-issue DAG — `## Scope` (mark each parallel \| sequential)                           |
| For agents   | ✓        | Exact file paths / entry points — `## For agents`                                           |
| Verification | ✓        | How we know it's done — `## Verification`                                                   |
| Sub-issues   | ✓        | List of `name :: one-line desc` — one per concern (the skill numbers + prefixes them)        |
| Depends on   | optional | `#N` list → native GitHub `blocked_by` edge + a `## Relations` line (the visible chain)      |
| Priority     | optional | `p0`–`p3` → `priority:<p>` label (default `p1`)                                             |
| Milestone    | optional | Inherited onto the parent (sub-issues inherit it too)                                       |

## Execution

```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/kit-config.sh" && load_kit_config
[[ "$KIT_PROJECTS_V2" == "true" ]] && { source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/gh-project.sh"; load_project_ids; }
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/role-identity.sh" 2>/dev/null || true
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/effort.sh"
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/effort-metrics.sh"   # effort_ctx_bucket

# TITLE = the human NAME only; the board title is composed as "[Effort] <N> · [<FLOW>] <TITLE>"
# (N is injected after creation — it's the issue's own number). FLOW is an optional controlled-vocab tag.
FLOW_TAG=""; [[ -n "${FLOW:-}" ]] && FLOW_TAG="[$FLOW] "

# 0. Guard the title content BEFORE creating anything: concise, no jargon, valid flow tag.
#    Lint with a placeholder number — the rule is about the NAME, not the (not-yet-assigned) N.
effort_title_lint "[Effort] 0 · ${FLOW_TAG}${TITLE}" \
  || { echo "✗ fix the effort title (above) before creating — concise / no-jargon / valid flow" >&2; return 1; }

# 1. Compose the parent body (the 4 sections) + an optional ## Relations chain.
RELATIONS=""
if [[ -n "${DEPENDS_ON:-}" ]]; then
  RELATIONS=$'\n\n## Relations\n'
  for d in ${DEPENDS_ON//,/ }; do d="${d#\#}"; RELATIONS+="- Depends on #$d"$'\n'; done
fi
PARENT_BODY=$(cat <<EOF
## Goal

$GOAL

## Scope

$SCOPE

## For agents

$FOR_AGENTS

## Verification

$VERIFICATION$RELATIONS
EOF
)

# 2. Create the parent issue (the plan). kind:task is the effort default unless overridden. Labels
#    add `ctx:*` (session weight, first-pass from the sub count; refined at kit-effort-start) + an
#    optional `flow:<flow>` tag.
SUBCOUNT=$(printf '%s\n' "$SUBS" | grep -c . 2>/dev/null || echo 1); [[ "$SUBCOUNT" -ge 1 ]] || SUBCOUNT=1
CTX="$(effort_ctx_bucket 1 "$SUBCOUNT")"
FLOW_LABEL=""; [[ -n "${FLOW:-}" ]] && FLOW_LABEL=",flow:$(printf '%s' "$FLOW" | tr '[:upper:]' '[:lower:]')"
PARENT_URL=$(gh issue create --repo "$KIT_REPO" \
  --title "[Effort] PLACEHOLDER · ${FLOW_TAG}${TITLE}" \
  --body "$PARENT_BODY" \
  --label "$CTX,kind:task,priority:${PRIORITY:-p1},role:$ROLE$FLOW_LABEL" \
  ${MILESTONE:+--milestone "$MILESTONE"})
PARENT_NUM=$(basename "$PARENT_URL")
# Inject the real effort id (== the issue number) into the title now that we have it.
gh issue edit "$PARENT_NUM" --repo "$KIT_REPO" --title "[Effort] $PARENT_NUM · ${FLOW_TAG}${TITLE}" >/dev/null
echo "✓ parent #$PARENT_NUM — $PARENT_URL"

# 2b. Native dependency edges from DEPENDS_ON — the visible board chain.
if [[ -n "${DEPENDS_ON:-}" ]]; then
  for d in ${DEPENDS_ON//,/ }; do d="${d#\#}"; effort_set_blocked_by "$PARENT_NUM" "$d"; done
fi

# 3. Add the parent to the board, set Status=Todo + Role (if Projects v2 is enabled).
if [[ "$KIT_PROJECTS_V2" == "true" ]]; then
  PARENT_NODE=$(gh api "repos/$KIT_REPO/issues/$PARENT_NUM" --jq .node_id)
  PARENT_ITEM=$(project_add_item "$PARENT_NODE" 2>/dev/null || echo "")
  if [[ -n "$PARENT_ITEM" ]]; then
    project_set_single_select "$PARENT_ITEM" "$STATUS_FIELD_ID" "$STATUS_OPT_TODO"
    ROLE_OPT=$(role_option_id "$ROLE" 2>/dev/null || echo "")
    [[ -n "$ROLE_OPT" ]] && project_set_single_select "$PARENT_ITEM" "$ROLE_FIELD_ID" "$ROLE_OPT"
  fi
fi

# 4. Create each sub-issue, link it natively under the parent, add it to the board.
#    SUBS is a newline-delimited list of "name :: one-line description". The skill numbers them
#    1..k and composes the "[Effort <parent>] <M> · <name>" title (effort-model.md), linting each.
#    Sub-issue bodies are intentionally short: the parent carries the narrative.
SUB_M=0
printf '%s\n' "$SUBS" | while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  SUB_M=$((SUB_M + 1))
  SUB_NAME="${line%% :: *}"
  SUB_DESC="${line#* :: }"; [[ "$SUB_DESC" == "$line" ]] && SUB_DESC=""
  SUB_TITLE="[Effort $PARENT_NUM] $SUB_M · $SUB_NAME"
  effort_title_lint "$SUB_TITLE" \
    || { echo "  ✗ sub title fails the rule (above) — rename and re-run: $SUB_TITLE" >&2; continue; }
  SUB_URL=$(gh issue create --repo "$KIT_REPO" \
    --title "$SUB_TITLE" \
    --body "$SUB_DESC

Sub-issue of #$PARENT_NUM (effort)." \
    --label "kind:task,priority:${PRIORITY:-p1},role:$ROLE" \
    ${MILESTONE:+--milestone "$MILESTONE"})
  SUB_NUM=$(basename "$SUB_URL")
  echo "  ✓ sub #$SUB_NUM — $SUB_TITLE"

  # Native parent/child link via the sub-issues REST API (child DB id, not number).
  effort_link_sub "$PARENT_NUM" "$SUB_NUM"

  # Board: add sub, Status=Todo + Role.
  if [[ "$KIT_PROJECTS_V2" == "true" ]]; then
    SUB_NODE=$(gh api "repos/$KIT_REPO/issues/$SUB_NUM" --jq .node_id)
    SUB_ITEM=$(project_add_item "$SUB_NODE" 2>/dev/null || echo "")
    if [[ -n "$SUB_ITEM" ]]; then
      project_set_single_select "$SUB_ITEM" "$STATUS_FIELD_ID" "$STATUS_OPT_TODO"
      ROLE_OPT=$(role_option_id "$ROLE" 2>/dev/null || echo "")
      [[ -n "$ROLE_OPT" ]] && project_set_single_select "$SUB_ITEM" "$ROLE_FIELD_ID" "$ROLE_OPT"
    fi
  fi
done

echo "✓ effort #$PARENT_NUM created — next: /kit-effort-start $PARENT_NUM"
```

## Output

- Parent issue URL + number (the plan)
- One line per sub-issue (number + title + native-link confirmation)
- Parent + all subs on the board at Status=Todo with the Role field set (if Projects v2 is on)
- Suggested next: `/kit-effort-start <parent>`

## Rules

- **The parent issue IS the plan** — never write a separate plan file; see `plan-output-format.md`.
- **Titles pass `effort_title_lint`** — concise, plain-language outcome, optional `[Flow]` tag from
  the controlled vocabulary; no jargon / glyphs / code identifiers / parentheses / sub-clauses /
  >6 words. The skill refuses to create an effort whose title fails. Detail goes in the body.
- **Carry the flow + the chain** — set `Flow` so the title shows `[Flow]` and the `flow:<flow>` label
  is applied; pass `Depends on #N` so the native GitHub `blocked_by` edge + a `## Relations` line make
  the chain visible on the board. `ctx:*` (session weight) is applied automatically.
- The parent body MUST carry all four template sections (Goal / Scope / For agents / Verification) —
  a missing section is a review blocker.
- Sub-issues are **native** GitHub sub-issues (`POST …/issues/{parent}/sub_issues` with the child's
  **database id**, resolved via `gh api repos/$KIT_REPO/issues/$N --jq .id`) — not just a checklist.
- Sub-issue bodies stay short (one line) — the parent holds the narrative.
- Never invent scope: ask for the sub-issue list if not provided.
- Scrub secrets from any pasted path/snippet before it enters the issue body (trace hygiene).
