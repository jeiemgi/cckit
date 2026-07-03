---
name: kit-plan-next
description: >
  Forward planning from the current state: run `cckit plan-next` to inventory what the kit can
  already do (skills, verbs, rules, docs) and propose what to build next — grounded in that
  inventory — then hand a chosen item off into `/kit-effort-new`. The proposed plan always carries a
  mandatory docs + README step.
when_to_use: >
  When you ask "given where we are, what should we build next?" — at the start of a chapter of work,
  after closing an effort, or when triaging a backlog against the kit's current capabilities. Not
  for ordering issues that already exist (that is `/kit-next` / `cckit plan`), and not for scoping an
  effort you have already chosen (go straight to `/kit-effort-new`).
metadata:
  version: 1.0.0
---

# kit-plan-next — what to build next, grounded in current state

Answer one question: **given everything the kit can already do, what is the highest-value next
effort?** This wraps the `cckit plan-next` verb (the engine — never re-author its logic here;
kit-engine-boundary) and turns its proposals into a scoped effort via `/kit-effort-new`.

The verb introspects the CURRENT capability surface at runtime, so the plan is always consistent
with what ships today — planning pre-grounded in current docs/skills/rules means the executing agent
burns fewer tokens rediscovering context.

## CRITICAL — context-anxiety rule

The plan `cckit plan-next` emits is **human / orchestrator-facing only**. NEVER paste it (or the
inventory) into a monitored model's prompt or context, and never wire it into an agent's context
automatically. Read it yourself, decide with the human, and hand only the CHOSEN item to
`/kit-effort-new`. See `rules/plan-next.md`.

## 1. Get the forward plan

```
cckit plan-next
```

Prints the current capabilities (skills / commands / rules / docs counts + samples) and a ranked,
grounded set of proposals. Rank 1 is **always** the mandatory docs + README step (docs-always rule —
it is never dropped, even for a tiny change). Append `--llm` for TOON rows `{rank,area,proposal,next}`
if you need to reason over the proposals structurally — but keep that output out of any monitored
context.

Run it from the cckit repo for a full inventory, or from a host project where the kit is installed —
there it degrades gracefully to whatever capability dirs exist (host docs only) and never crashes.

## 2. Choose with the human

Surface the proposals as a short, visual summary — lead with the human-meaningful outcome of each
item (its `proposal`), not the verb noise. Confirm which one to pursue. Do not invent scope beyond
what the inventory supports.

## 3. Hand off to /kit-effort-new

Once an item is chosen, scope it into an effort:

```
/kit-effort-new
```

Carry the chosen proposal into the effort's **Goal**, decompose it into sub-issues in **Scope**, and
**always include the mandatory docs + README sub-issue** — the planner surfaces it on every plan and
`/kit-effort-new` must preserve it (docs are part of "done," never a follow-up).

## Output

- The current-capability inventory (counts + samples per area).
- A ranked, grounded proposal table — rank 1 is always docs + README.
- A chosen item handed to `/kit-effort-new` as a new effort (Goal / Scope / For agents / Verification).

## Rules

- **Engine boundary** — the planning logic lives in `scripts/lib/plan-next.sh` (`plan_next`); this
  skill only runs the verb and routes the result. Never re-implement the inventory or proposals here.
- **Docs are mandatory** — every plan carries a docs + README step; the effort you scope must keep it.
- **Context-anxiety** — planner output never enters a monitored model's context; it informs the
  human/orchestrator's decision only.
- **Don't plan what exists** — for ordering already-created issues use `/kit-next` or `cckit plan`;
  for scoping an item you've already chosen go straight to `/kit-effort-new`.
- Scrub secrets from anything pasted into the resulting effort body (trace hygiene).
