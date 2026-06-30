---
name: kit-effort-new
description: Create an effort — a parent GitHub issue using the effort-model template (Goal / Scope / For agents / Verification) plus N native GitHub sub-issues linked via the sub-issues REST API, all added to the project board. The parent issue IS the plan.
when_to_use: When starting a new unit of work (a "plan"/effort) that decomposes into several sub-tasks. Replaces ad-hoc `gh issue create` for multi-part work. The effort splits into native sub-issues at scoping time; sequential subs commit on the effort branch, parallel subs use file-disjoint worktrees and merge in. See rules/effort-model.md.
---

# kit-effort-new

Plugin-direct skill — runs straight from `${CLAUDE_PLUGIN_ROOT}` (no per-project `scripts/` checkout
needed). It is a **thin caller** of the shared creation core `effort_new` (`scripts/lib/effort-ops.sh`)
— the exact function `cckit effort new` runs — so the skill and the verb produce structurally
identical efforts (effort #98). No creation logic is re-authored inline (kit-engine-boundary #1/#2).
Repo + board config come from `load_kit_config` (`$KIT_REPO`, `KIT_PROJECTS_V2`). Reads
`.claude/kit.config.json` from the working directory.

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

This skill is a **thin caller** of the shared creation core `effort_new`
(`scripts/lib/effort-ops.sh`) — the SAME function `cckit effort new` runs (effort #98). The core owns
body composition, the `ctx/kind/priority/role/flow` label set, per-sub title lint, native sub-issue
links, `blocked_by` edges, and the board add. There is no second implementation here.

```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/kit-config.sh" && load_kit_config
# Board + role helpers must be loaded BEFORE effort_new so its (guarded) board add can run.
if [[ "$KIT_PROJECTS_V2" == "true" ]]; then
  source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/gh-project.sh"; load_project_ids
  source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/role-identity.sh" 2>/dev/null || true
fi
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/effort.sh"
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/effort-metrics.sh"   # effort_ctx_bucket
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/effort-ops.sh"       # effort_new — the shared creation core

# TITLE = the human NAME only (no "[Effort]"/number prefix). The core composes the board title
# "[Effort] <N> · [<FLOW>] <TITLE>", fills the four sections, applies labels, and lints the parent +
# every sub title up front (a bad name aborts before anything is created — no half-effort).

# SUBS is a newline-delimited list of "name :: one-line description"; pass each line as a positional
# sub spec. The core numbers them 1..k and composes the "[Effort <parent>] <M> · <name>" title.
SUB_ARGS=()
while IFS= read -r line; do [[ -n "$line" ]] && SUB_ARGS+=("$line"); done <<< "$SUBS"

# effort_new echoes the parent number on stdout (progress goes to stderr) — capture it for the hint.
PARENT_NUM=$(effort_new \
  ${FLOW:+--flow "$FLOW"} \
  --role "$ROLE" \
  --priority "${PRIORITY:-p1}" \
  --goal "$GOAL" --scope "$SCOPE" --for-agents "$FOR_AGENTS" --verification "$VERIFICATION" \
  ${DEPENDS_ON:+--depends-on "$DEPENDS_ON"} \
  ${MILESTONE:+--milestone "$MILESTONE"} \
  "$TITLE" "${SUB_ARGS[@]}")
echo "✓ effort #$PARENT_NUM created — next: /kit-effort-start $PARENT_NUM"
```

> The block above is intentionally short: all creation logic lives in `effort_new`. If you need to
> change what an effort looks like (body, labels, lint, board), change the core — both the skill and
> the verb move together.

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
