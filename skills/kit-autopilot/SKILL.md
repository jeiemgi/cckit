---
name: kit-autopilot
description: Autonomous execution under hard caps — run ONE long objective hands-off, OR drive the planned effort/flow set in parallel. On an APPROVED plan the captain DECIDES, MERGES each wave, and CONTINUES; it pings the human ONLY on a genuine blocker. THIN wrapper over the built-in /loop + the kit's orchestrate scripts; never a new engine.
when_to_use: When delegating work to run unattended — a single capped objective (overnight) or several planned flows at once without tab-juggling. A verifiable stop condition is required. Maps to Kun Chen's "Good Night Have Fun" (the loop) and "First Mate" (the multi-flow captain). Not for one-off tasks (just do them) or open-ended work with no measurable stop.
---

# kit-autopilot — capped, hands-off execution

One skill, two modes — both delegate work that runs **autonomously to a verifiable stop, under hard
caps**. It is a **thin wrapper**: it composes the built-in `/loop` and the kit's `orchestrate`
scripts; it never reimplements looping or orchestration.

| Mode          | What runs                                                   | Wraps                                                         |
| ------------- | ----------------------------------------------------------- | ------------------------------------------------------------- |
| **objective** | one long objective on the current branch                    | the built-in `/loop` + caps + a stop-check                    |
| **plan**      | the planned, file-disjoint set of efforts/flows in parallel | `kit effort plan` + `orchestrate.sh` + `orchestrate-watch.sh` |

## Established-plan autonomy (the default)

**When the plan is already approved, the captain DECIDES + MERGES + CONTINUES — it does not bounce
back to the human to confirm a planned step.** "Do these efforts with the new flow", an approved
`kit effort plan`, or a green wave are an **established plan**: execute it end to end —
build a wave → merge its PRs → close subs+parent → gc → launch the next wave — **without asking
"merge or review?"**. A planned merge is _execution_, not a new decision. (José, "Error 1", 2026-06-28.)

- The human steers the **plan**, not each merge. Asking to confirm a routine planned merge is the error.
- A `risk:med` change the plan already approved (a product feature in the agreed scope) is **not** a
  reason to stop — the plan blessed it. The risk-tiered review tiers
  (`risk-tiered-review.md`) govern **ad-hoc** PRs, **not** execution of an approved plan.

### Ping the human ONLY on a genuine blocker

Interrupt only when the plan genuinely can't proceed without a human:

- an **unresolvable merge conflict** the captain can't safely resolve;
- a **surprise always-human change not implied by the plan** — a NEW dependency/lockfile,
  security/auth/secret, or `.github/workflows/**` edit the plan didn't call for;
- a **real ambiguity the plan doesn't cover** (a fork the approved scope is silent on);
- a **destructive/irreversible step outside the plan**.

Everything else: decide, land it, report on completion. Quiet by default, loud only on a true blocker.

## The contract (hard — both modes)

- **Caps are mandatory and hard.** A run declares a token budget, an iteration cap, and a
  **verifiable** `--until` stop-check. Autopilot refuses to start without them and never raises its
  own budget mid-run.
- **Plan mode merges its waves.** Driving an approved plan, the captain merges each wave's PRs
  (squash), closes subs+parent, and gc's — then advances any effort that was `blocked_by` it.
- **Objective mode never auto-merges its own run.** A single capped objective lands commits on its
  branch; the merge is the captain's/human's call under the plan, not the loop's.
- **Never free-spawn (plan mode).** The parallel set comes from `kit effort plan`, never improvised;
  co-launch only **file-disjoint** efforts (sequence the rest).

## Mode: objective (single capped run)

```
kit autopilot "<objective>" --max-tokens N --max-iters K --until "<check>"
```

| Flag                | Meaning                                                                     | Default  |
| ------------------- | --------------------------------------------------------------------------- | -------- |
| `<objective>`       | the goal in one line (e.g. "make the build pass and open a PR")             | required |
| `--max-tokens N`    | hard token budget for the whole run                                         | required |
| `--max-iters K`     | hard cap on loop rounds                                                     | required |
| `--until "<check>"` | a command that exits 0 when done (`typecheck`, a build, a test, a PR state) | required |

**Execution:** validate caps -> drive `/loop` with the objective -> after each round evaluate the
stop conditions -> commit each round's progress (commit-early; an unattended run must be durable if
the session dies). Work stays on the branch it started on (one branch per worktree).

## Mode: plan (drive the parallel set)

```
kit autopilot --plan            # read the plan and launch the planned set
```

1. **Read the plan** — `kit effort plan` groups open efforts by `flow:`, orders each flow by its
   `blocked_by` edges, sizes each by `ctx:*`, and declares fan-out per effort via `par:*`. That
   output IS the launch plan — the set, the order, and the budget are read from it, not chosen.
2. **Launch** — `orchestrate.sh <issueA> <issueB> ...` (one worktree per effort, file-disjoint;
   respect `par:*`/`blocked_by` so blocked efforts wait). Use `--notify`.
3. **Babysit** — `orchestrate-watch.sh` (launched by `--notify`) signals PR open / conflict / failing
   checks / merged, and GCs each worktree + branch on merge.
4. **Decide + advance** — as each wave's gates go green, **merge it** (established-plan autonomy
   above) and advance any effort that was `blocked_by` it. Surface to the human only a genuine blocker.

## On wake / on a pause (the report — always)

- **Branch(es)** + final short HEAD, or per-flow PRs (plan mode).
- **Commits made** this run (count + one-line subjects).
- **Why it stopped** — cap hit / check passed / stalled / waves landed / a genuine blocker (what + the decision needed).
- **State** — objective verifiably done, or parked (and the next step a human needs).

## Stop conditions (any one ends a run)

1. **Cap hit** — `--max-tokens` or `--max-iters` reached.
2. **Check passes** — `--until` exits 0, or all planned waves are merged.
3. **No new progress** — no new commit / no measurable advance for K rounds (stall guard).
4. **Genuine blocker** — pause + report (see above).

## Rules

- **Never start without a verifiable check** — an uncapped, uncheckable run is banned.
- **Thin wrapper only** — never grow a second loop or orchestration engine here; if `/loop` or the
  orchestrate scripts lack something, fix them at the source.
- **Adopt-first** — evaluate Kun Chen's open-source **GNHF** (the loop) and **First Mate** (the
  captain) before extending this native skill; this is the thin native version.
