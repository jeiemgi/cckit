# Effort model — the unit of work (and of the work record)

**GitHub is the single source of truth.** An *effort* is the kit's larger unit of work: bigger than
a single task, with its own decomposition. The same structure that organizes the work also produces
a clean, per-unit **record** of it (goal → plan → patch → verify) — useful for review, audit, and as
a dataset if you train on your own development history.

> Two flows coexist in the kit. Use **tasks** (`task-*`) for a single self-contained change; use
> **efforts** (`effort-*`) when one goal decomposes into several sub-tasks that build toward one PR.

## The unit

**1 effort = 1 parent issue · 1 branch · 1 worktree · 1 PR.** No forced tiny PRs — a big effort-PR
is fine while building. 1 effort decomposes into **N native GitHub sub-issues** (parallel or
sequential, decided at scoping).

```
parent issue #N  ──►  effort/<N> branch + worktree (from main)
   ├─ sub #a ─► sub/<N>a worktree (from effort/<N>)  ─┐
   ├─ sub #b ─► sub/<N>b worktree                     ├─ merge into effort/<N>
   └─ sub #c ─► sub/<N>c worktree                     ┘
effort/<N>  ──►  ONE PR ──►  main  ──►  effort-close
```

Solo/sequential efforts may commit sub-issues directly on `effort/<N>` (one commit per sub-issue —
the commit diff is that sub-issue's patch). Parallel sub-issues use their own worktrees
(file-disjoint) and merge in.

## Parent-issue template

Every parent issue body uses these four sections (they double as the columns of the work record):

```markdown
## Goal           → problem statement
What outcome, in one or two lines.

## Scope          → plan (the sub-issue DAG; mark each parallel | sequential / dependsOn)
The decomposition. Sub-issues are linked natively (GitHub parent/child).

## For agents     → retrieval context
Exact file paths / entry points a future agent needs to find the code fast.

## Verification   → label / acceptance
How we know it's done (commands, checks, acceptance).
```

**Effort + sub-issue titles must be recognizable on the board:**

- **Umbrella / parent issue:** **`[Effort] <number> · <Name>`** — the literal `[Effort]` tag, the
  issue's own number, then the human name. e.g. `[Effort] 42 · Auth hardening`.
- **Sub-issue:** **`[Effort <parent>] <N> · <Title>`** — the parent's number in the tag, then a
  **numeric** sequence index `N` (1, 2, 3 — **never letters** like A/B/C), then the title.
  e.g. `[Effort 42] 1 · Add rate limiting to /login`.

The parent ref is mandatory; `N` is a plain number so subs sort and read predictably. `effort-new`
applies both formats when it creates the parent + native sub-issues, so a sub is identifiable by
name alone in any flat list.

**One creation core (no drift).** Both ways to create an effort — the `cckit effort new` verb and
the `/kit-effort-new` skill — call the **same** shared function `effort_new` (`scripts/lib/effort-ops.sh`).
That single core fills the four body sections, applies the `ctx/kind/priority/role/flow` label set
(`ctx:*` via `effort_ctx_bucket`), lints the parent **and every sub** title up front, links the
native sub-issues, and adds everything to the board. Change the core and both move together; there
is no second implementation. `scripts/setup-labels.sh` provisions every label family the core
applies (`ctx:* flow:* kind:* priority:* role:*`) so creation never fails on a missing label.

### Title rule, flow tags, relations, session-fit

The board should be **legible at a glance** — a title says *what* an effort delivers and *which
flow* it belongs to; the *chain* (who blocks whom) and the *session weight* are machine-readable.

**Concise, jargon-free titles (lint-enforced).** The `<Name>` part of an effort/sub title is a short
plain-language **outcome** with an optional leading `[Flow]` tag:

- **Format:** `[Effort] N · [Flow] short name` (parent) · `[Effort N] M · short name` (sub).
- **Banned in the name:** glyphs (`— ▾ ▸ → ✓ ✗ … •`), parentheses, ` — ` / ` · ` / ` / ` sub-clauses,
  code identifiers (file names, paths, `snake_case`), internal jargon (`chrome`, `seam`, `contract`,
  `rescue stash`, `refactor`, `wiring`, …), and **> 6 words**. Detail goes in the body.
- **`effort_title_lint`** (`scripts/lib/effort.sh`) is the check; `effort-new` lints the parent **and
  every sub** title up front and refuses to create anything if one fails. Bad→good:
  `operator chrome — Settings ▾ dropdown + fixes` → **`[UI] operator navigation`**.

**Flow tag (`[Flow]` + `flow:<flow>` label).** A **flow** is a named thread of efforts toward one
outcome. Controlled vocabulary (`EFFORT_FLOWS` in `effort.sh`; a project overrides it). The title
carries `[Flow]` so membership reads off the board; the `flow:<flow>` label makes it filterable.

**Relations (the chain) — native edge + `## Relations` mirror.** Cross-effort dependencies are
**both** a native GitHub dependency (`blocked_by` — the edge GitHub renders on the issue/board, set
by `effort_set_blocked_by`) **and** a `## Relations` section in the parent body (the human-readable
mirror): `Depends on #N` / `Blocks #N` / `Extends #N` / `Parallel-safe with #N`. This is the
effort-level analogue of the PR-level `Depends on` in `branch-naming.md`.

**Session-fit (`ctx:*` + `kit effort plan`).** Every effort carries a **`ctx:S|M|L|XL`** label —
how much of one working session it consumes before the context window fills. Derived by
`effort_ctx_bucket` (`scripts/lib/effort-metrics.sh`) from difficulty + sub count: S=1 · M=2 · L=4 ·
XL=8 weight. **`kit effort plan`** (`scripts/lib/effort-plan.sh`) reads the open efforts, groups by
flow, orders each flow by the `blocked_by` edges, and packs them into **session-sized batches** under
a budget (`KIT_SESSION_BUDGET`, default 4). L/XL efforts are flagged **"→ delegate subs"**:
delegating an effort's sub-issues to **sub-agents in their own worktrees** keeps the main session
light (a sub-agent reads/writes in its own context; only a summary returns) — the lever that lets
more efforts fit one session (`rules/agent-execution-routing.md`).

Sub-issue bodies: a one-line description is enough (title is for humans, short desc not required).
The parent carries the rich narrative; the **PR** carries the human-facing review write-up + a
`## For agents` section.

## Lifecycle (the commands — see the effort-* skills)

| Step | What |
|------|------|
| `effort-new` | parent issue (4-section body **filled** + `ctx/kind/priority/role/flow` labels) + native sub-issues, every title linted |
| `effort-start <N>` | `effort/<N>` branch + worktree; board → In Progress |
| orchestrate | sub-issues in own worktrees (file-disjoint) → merge into `effort/<N>`; each closes + board Done as it lands |
| `effort-pr <N>` | ONE PR `effort/<N>` → main (rich body + `## For agents`) |
| `effort-close <N>` | **snapshot sub-diffs pre-squash** → merge → close parent + subs → board Done(all) → GC prune → kit-sync drift check |

Board + record state are correct **by construction** — the close op owns them. Never rely on a
separate, skippable "mark done" step.

## Plans are issues, not files

The parent issue **is** the plan. Strategy / roadmap narrative lives in your knowledge base; the
"where we stand" view is generated from GitHub issue data, never hand-authored. → `plan-output-format.md`.

## Trace hard rules

- Snapshot each sub-branch diff **before squash** (squash destroys per-sub-issue pairs) — `effort-close`
  step (a) does this automatically, to a durable dir under the shared git-common-dir.
- Scrub secrets from diffs/bodies before they enter an issue or any exported record.
- Keep client/tenant data out of the dev-workflow record (it is not your development history).
- Outcome labels: merged-clean = positive · abandoned/reverted = negative · a manual flag for exemplars.
