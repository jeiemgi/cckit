# Plan-next — forward planning from the current state

cckit plans **forward from what already ships**. `cckit plan-next` (and the `/kit-plan-next` skill)
introspect the kit's CURRENT capability surface at runtime — skills, verbs/commands, rules, docs —
and propose what to build next, grounded in that inventory. This is the productized form of the
manual "given where we are, here is what to build next" triage.

> Two planners coexist, and they answer different questions. `cckit plan` / `/kit-next` order the
> issues that **already exist** (deps-ordered, file-disjoint waves). `cckit plan-next` proposes the
> issues that **don't exist yet**, derived from gaps in the current capability surface. Use plan-next
> to decide *what* to create; use plan / next to decide *in what order* to do the created work.

## Where it sits in the workflow

```
cckit plan-next        →  propose next efforts (grounded in current skills/verbs/rules/docs)
   └─ /kit-plan-next   →  choose one with the human, hand off to:
        └─ /kit-effort-new  →  scope it into a parent issue + sub-issues (effort-model.md)
             └─ cckit plan / cckit next  →  order + drive the now-existing work
```

It is the front of the funnel: it feeds [`/kit-effort-new`](effort-model.md), which produces the
unit of work the rest of the lifecycle drives.

## The mandatory docs + README step (docs-always)

**Every plan plan-next emits carries a docs + README update step as rank 1 — non-negotiable, never
dropped, even for a tiny change.** Docs are part of "done," not a follow-up. When you scope a chosen
proposal into an effort, that effort MUST keep a docs + README sub-issue. The planner surfaces this
on every plan precisely so it cannot be forgotten; `/kit-effort-new` must preserve it.

## Grounded, not generative

The proposals are deterministic and derived from the inventory, not invented:

- **Coverage gaps** — skills or verbs that ship but are not referenced in any doc page become
  "document X" proposals.
- **Thinnest area** — the capability area with the fewest entries becomes a "deepen X" proposal, so
  there is always at least one concrete next effort beyond docs.

Run it from the cckit repo for a full inventory, or from a host project where the kit is installed —
there it degrades gracefully to whatever capability dirs exist (host docs only) and never crashes.

## Critical — context-anxiety rule

**The plan-next output is HUMAN / orchestrator-facing ONLY.** It must NEVER be injected into a
monitored model's prompt or context, and it is never wired into any agent's context automatically.

The thesis is the opposite of context-stuffing: planning that is *pre-grounded* in the current
docs/skills/rules means the EXECUTING agent burns fewer tokens rediscovering what the kit can do —
the plan informs the human/orchestrator's decision, then only the CHOSEN, scoped effort reaches an
agent. The plan itself is not agent-context fuel. The verb states this in its output footer; the
skill states it up front; both honor it.

## See also

- [effort-model.md](effort-model.md) — the unit of work a chosen proposal becomes.
- [plan-output-format.md](plan-output-format.md) — the format for any written "plan" deliverable.
