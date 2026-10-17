---
name: kit-autopilot
description: Autonomous execution under hard caps — run ONE long objective hands-off, OR drive the planned effort/flow set in parallel. On an APPROVED plan the captain DECIDES, MERGES each wave, and CONTINUES; it pings the human ONLY on a genuine blocker. THIN wrapper over the built-in /loop + the kit's orchestrate scripts; never a new engine.
when_to_use: When delegating work to run unattended — a single capped objective (overnight) or several planned flows at once without tab-juggling. A verifiable stop condition is required. Maps to Kun Chen's "Good Night Have Fun" (the loop) and "First Mate" (the multi-flow captain). Not for one-off tasks (just do them) or open-ended work with no measurable stop.
---

# kit-autopilot — capped, hands-off execution

## Current implementation limit

The current `cckit autopilot` CLI launches issue flows through `orchestrate.sh`. It accepts
issue numbers, `--cap`, `--agent`, `--dry-run`, `--no-seed`, `--force`, and `--session`.
The objective, `--plan`, `--max-tokens`, `--max-iters`, `--until`, and `--notify` examples below
are workflow requirements, not implemented CLI flags. Do not invoke them as working commands.
Before accepting an unattended objective, verify that the selected runtime actually enforces each
requested limit. If it cannot, report the unsupported limit and do not start that bounded run.
A prompt asking an agent to stay under a token budget does not enforce that budget.
Implementation and cross-runtime verification are tracked in cckit effort #257, sub-issue #264.

**Exception — night mode.** The Workflow runtime does enforce a token budget, so an approved plan
can run unattended through `scripts/night-run.mjs` (see _Mode: night_ below). The CLI flags above
are still unimplemented.

One skill, two modes — both delegate work that runs **autonomously to a verifiable stop, under hard
caps**. It is a **thin wrapper**: it composes the built-in `/loop` and the kit's `orchestrate`
scripts; it never reimplements looping or orchestration.

| Mode          | What runs                                                   | Wraps                                                         |
| ------------- | ----------------------------------------------------------- | ------------------------------------------------------------- |
| **objective** | one long objective on the current branch                    | the built-in `/loop` + caps + a stop-check                    |
| **plan**      | the planned, file-disjoint set of efforts/flows in parallel | `kit effort plan` + `orchestrate.sh` + `orchestrate-watch.sh` |

> Need the plan first? `/kit-plan-next` (`cckit plan-next`) proposes what to build next from the
> kit's current capabilities, then hands a chosen item to `/kit-effort-new` — the effort autopilot
> later drives. Keep that planner output with the human/orchestrator; never feed it into a monitored
> agent's context (context-anxiety rule).

## Established-plan autonomy (the default)

**When the plan is already approved, the captain DECIDES + MERGES + CONTINUES — it does not bounce
back to the human to confirm a planned step.** "Do these efforts with the new flow", an approved
`kit effort plan`, or a green wave are an **established plan**: execute it end to end —
build a wave → merge its PRs → close subs+parent → gc → launch the next wave — **without asking
"merge or review?"**. A planned merge is _execution_, not a new decision (the canonical "Error 1" incident: stalling an approved plan to ask for a routine merge).

- The human steers the **plan**, not each merge. Asking to confirm a routine planned merge is the error.
- A `risk:med` change the plan already approved (a product feature in the agreed scope) is **not** a
  reason to stop — the plan blessed it. The risk-tiered review tiers
  (`risk-tiered-review.md`) govern **ad-hoc** PRs, **not** execution of an approved plan.
- **The permission is shipped, not improvised.** `cckit init` scaffolds a **versioned**
  `.claude/settings.json` (from `templates/settings/settings.json.tmpl`) whose explicit
  `Bash(gh pr merge:*)` allow pre-authorizes the wave-merge — checked in, so it travels to every
  worktree and collaborator (the gitignored `settings.local.json` does not). A captain merge that
  still prompts means the project predates the template: re-run `cckit init --upgrade`.

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

## Mode: night (an approved plan, unattended, through a Workflow)

The one mode whose caps a runtime enforces. `scripts/night-run.mjs` is a Workflow script: the
Workflow runtime throws once the `+N` budget is spent, and the script holds the rest of the caps in
code.

**Before the owner leaves** — the plan is approved (no effort still carries `grill:assumed`) and
the owner posts the night grant: ONE comment on the plan parent issue. The latest grant wins.

````markdown
<!-- night-grant -->
Tonight: run the two approved waves. I accept the lockfile floor.

```json
{ "budget": "+2000k", "waves": [[12], [15]], "waivers": ["lockfile"], "stopCommand": null }
```
````

**Launch** — from the repo root:

1. `scripts/night-grant.sh preflight` — exit 1 names the allowlist entries an unattended run lacks
   in the tracked `.claude/settings.json` (merge, push, issue comment/edit/close, `gh api`). Stop and
   tell the owner; it never edits the file.
2. `scripts/night-grant.sh read <parent>` — prints the engine args (line 1) and `budget=+N`
   (line 2), or refuses a malformed grant or a never-waivable waiver.
3. Launch the Workflow with line 1 as `args` and the budget as the `+N` directive. The runtime
   counts the **whole turn**, the captain's own output included, so size `+N` with headroom.

| Cap | Value | Enforced by |
| --- | --- | --- |
| Token budget | the grant's `+N` | the Workflow runtime (`budget.total`); no budget = refused |
| Concurrency | ≤ 4 agents, whatever `maxConcurrent` says | the script, in groups of 4 |
| Wave reserve | 150k tokens left, or the next wave does not start | the script |
| Stall | 2 waves in a row with nothing merged | the script |
| Stop | every wave merged + the gate green on the base branch, or `stopCommand` exits 0 | the script |

**Floors.** Base floors: `lockfile`, `auth`, `security-code`, `security-prose`, `workflows`, `cost`,
`secret`. `security-prose` (a `security/*` diff that is prose only) is waived by standing rule;
`workflows`, `cost` and `secret` are never waived. A project adds its own floors, its own
never-waivable list and its gate command under `night` in the kit config:

```json
"night": { "floors": { "auth-dep": "the auth library version" },
           "neverWaivable": ["auth-dep"], "gate": "pnpm typecheck && pnpm lint" }
```

**Refused and parked.** An effort carrying `grill:assumed`, or with no `## Grilling`/`## Assumed`
section, is refused. A red gate or a floor the grant did not waive parks the effort for the owner.

**When it returns `usage-limit`** — an agent came back empty mid-wave. Do not relaunch. Sleep with
`ScheduleWakeup` until the window resets, then resume **one** workflow with `resumeFromRunId`.
Finished agents replay from cache; a sub whose commit already landed is never rebuilt.

**Every other stop** (`done`, `stall`, `budget`, `blocked`, `refused`) — write the wake report from
the returned `efforts` (status, reason, bare PR URL each), update the one status comment on the plan
parent, and stop. A plan grilled tonight carries `grill:assumed` and waits for the owner: a night
never plans and executes the same work.

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
