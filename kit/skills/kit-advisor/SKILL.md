---
name: kit-advisor
terms: Advisor
description: >
  Run project management as a mode of the builder: route a request to its stage (grill, plan,
  orchestrate, review, close), run that stage with the cckit verbs, and end every stage with a step
  report and its trail comment.
when_to_use: >
  "create an effort", "plan an effort", "plan the sprint", "brief the workers", "review the
  effort", "close the sprint". Not for one issue (kit-ship) or a plan already approved (kit-autopilot).
metadata:
  version: 1.0.0
---

# kit-advisor — the stage router

The advisor helps the owner decide the work and then keeps it honest. It writes no code: builders
do, in their own worktrees. Each stage below has one reference file; read only the one you route to.

## 1. Route the request

| The request | Stage | Reference |
| --- | --- | --- |
| a goal with open decisions: "create an effort", "grill me on this" | grill | `references/grill.md` |
| a grilled goal: "plan the effort", "plan the sprint", "what goes in this week" | plan | `references/plan.md` |
| a planned effort: "start it", "brief the workers", "run the wave" | orchestrate | `references/orchestrate.md` |
| landed subs: "review the effort", "is it done", "check the subs" | review | `references/review.md` |
| a finished sprint or effort: "close the sprint", "retro", "wrap up" | close | `references/close.md` |

Pick the earliest stage whose input is missing. A goal with no `## Grilling` record goes to grill,
even when the request said "plan": a plan built on undecided questions gets planned twice.

## 2. Find where the work stands

```bash
cckit status --board          # the open efforts, their subs, what is blocked
cckit effort sprint name      # the current sprint, Monday to Monday
cckit effort sprint list      # the sprints open on the forge, with their counts
```

Facts are looked up, never asked: the sprint, the subs, their state and their Specs come from these
verbs. Only decisions go to the owner.

## 3. Run the stage

Open its reference and follow it. Every stage uses the verbs it names and nothing else; a step the
verbs cannot do is a defect in the kit, so report it instead of hand-rolling `git` or `gh` calls.

| Stage | Main verbs |
| --- | --- |
| grill | `cckit page open` · `cckit effort new --grilling-file F` |
| plan | `cckit effort sprint open` · `cckit effort new --sprint` · `cckit effort sub --spec` · `cckit effort plan --issues --effort N` |
| orchestrate | `cckit effort start N` · `cckit brief <sub> --skills S --verbs V` · `cckit effort plan --wave --effort N` |
| review | `cckit effort review N` |
| close | `cckit effort sprint close` · `cckit effort close N` |

## 4. Report the stage

Every stage ends with a step report, in this order and no other:

**Status · Done · Waiting for a yes · Numbers · Failing or risky · Open questions · Next step**

Write it to `.cckit/reports/<YYYY-MM-DD-HHMM>-<effort>-<stage>.md`, then post its trail comment on
the effort issue:

```bash
cckit agent receipt <issue> --report .cckit/reports/<file>.md
```

The template and the rules for each section are in `references/step-report.md`.

## 5. Stop where the owner decides

Stop and ask at: the grill playback, a plan that adds cost, a sprint close, a release. Everything
mechanical (start, brief, merge on a green gate, close) the advisor runs and reports.
