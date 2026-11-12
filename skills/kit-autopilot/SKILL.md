---
name: kit-autopilot
description: Autonomous execution under hard caps — run ONE long objective hands-off, OR drive the planned effort/flow set in parallel. On an APPROVED plan the captain DECIDES, MERGES each wave, and CONTINUES; it pings the human ONLY on a genuine blocker. THIN wrapper over the built-in /loop + the kit's orchestrate scripts; never a new engine.
when_to_use: When delegating work to run unattended — a single capped objective (overnight) or several planned flows at once without tab-juggling. A verifiable stop condition is required. Maps to Kun Chen's "Good Night Have Fun" (the loop) and "First Mate" (the multi-flow captain). Not for one-off tasks (just do them) or open-ended work with no measurable stop.
---

# kit-autopilot — capped, hands-off execution

## Current implementation limit

`cckit autopilot [<issue> …]` launches issue flows through `orchestrate.sh`. It accepts issue
numbers, `--cap`, `--agent`, `--dry-run`, `--no-seed`, `--force`, and `--session`.

`cckit autopilot run [<issue>] --objective "<text>"` runs ONE objective headlessly on the current
branch (`claude -p` or `codex exec`) and enforces these in code: `--max-iters`, `--max-seconds`,
`--round-seconds`, `--until "<cmd>"`, `--check "<cmd>"`, and a stop on a round that changed
nothing. `--max-tokens` is checked between rounds only, from the usage the runtime prints, and a
round that prints none stops the run. `--notify` and `--plan` are refused: nothing implements them.
A run never merges. The stop reason and the resume command are in `.cckit/autopilot/<branch>.json`;
`cckit autopilot run --resume` continues with the counters carried over.

The `/kit-autopilot "<objective>"` examples below that pass `--plan` or `--notify` are workflow
requirements, not working commands. If a requested limit is not in the enforced list above, report
it as unsupported and do not start that bounded run. A prompt asking an agent to stay under a
token budget does not enforce that budget. The full table, including what no live run has
confirmed, is in the docs site's agent-compatibility page under "Unattended run limits".

**Exception — night mode.** The Workflow runtime does enforce a token budget, so an approved plan
can run unattended through `${CLAUDE_PLUGIN_ROOT}/scripts/night-run.mjs` (see _Mode: night_ below). The CLI flags above
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
  `Bash(cckit merge:*)` / `Bash(cckit watch:*)` allow pre-authorizes the wave-merge (a raw
  `gh pr merge` is blocked by the guard hook, #364) — checked in, so it travels to every
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
   `blocked_by` edges, and sizes each by `ctx:*`. That
   output IS the launch plan — the set, the order, and the budget are read from it, not chosen.
2. **Launch** — `orchestrate.sh <issueA> <issueB> ...` (one worktree per effort, file-disjoint;
   respect `blocked_by` so blocked efforts wait). Use `--notify`.
3. **Babysit** — `orchestrate-watch.sh` (launched by `--notify`) signals PR open / conflict / failing
   checks / merged, and GCs each worktree + branch on merge.
4. **Decide + advance** — as each wave's gates go green, **merge it** (established-plan autonomy
   above) and advance any effort that was `blocked_by` it. Surface to the human only a genuine blocker.

## Mode: night (an approved plan, unattended, through a Workflow)

The one mode whose caps a runtime enforces. `${CLAUDE_PLUGIN_ROOT}/scripts/night-run.mjs` is a
Workflow script: the Workflow runtime throws once the `+N` budget is spent, and the script holds the
rest of the caps in code. Both night scripts ship in the plugin, so every path below starts at
`${CLAUDE_PLUGIN_ROOT}` — a consuming project has no copy of them in its own checkout.

**Before the owner leaves** — the owner posts the night grant: ONE comment on the plan parent
issue. **The grant is the approval**: an effort runs tonight because the owner named its number in
`waves`. Nothing else marks an effort approved — no label, no body section.

**Only the owner's grant counts.** A grant sets the budget, the waivers and a shell `stopCommand`,
so `night-grant.sh read` keeps a marker comment only when GitHub reports its `author_association`
as `OWNER`, or its author is `github.owner` or a login in `night.grantors` (kit config). The latest
of those wins. A marker comment from anyone else is ignored and its author is named on stderr; when
no owner grant exists the read exits 1 and nothing launches. On an organization repo no commenter
is `OWNER` and `github.owner` is the org, so list the people who may grant in `night.grantors`.

````markdown
<!-- night-grant -->
Tonight: run the two approved waves. I accept the lockfile floor.

```json
{ "budget": "+2000k", "waves": [[12], [15]], "waivers": ["lockfile"], "stopCommand": null }
```
````

**Launch** — from anywhere inside the project (the kit config is found by `kit_config_path`:
`$KIT_CONFIG`, else a walk up from the current directory):

1. `bash "${CLAUDE_PLUGIN_ROOT}/scripts/night-grant.sh" preflight` — exit 1 names the allowlist
   entries an unattended run lacks in the tracked `.claude/settings.json` (merge, push, issue
   comment/edit/close, `gh api`). Stop and tell the owner; it never edits the file.
2. `bash "${CLAUDE_PLUGIN_ROOT}/scripts/night-grant.sh" read <parent>` — prints the engine args
   (line 1) and `budget=+N` (line 2), or refuses: no grant by the owner, a malformed grant, a
   waiver that is not exactly one floor name, a never-waivable waiver, or a WIP limit of 0.
3. Launch the Workflow script `${CLAUDE_PLUGIN_ROOT}/scripts/night-run.mjs` with line 1 as `args`
   and the budget as the `+N` directive. The runtime counts the **whole turn**, the captain's own
   output included, so size `+N` with headroom.

| Cap | Value | Enforced by |
| --- | --- | --- |
| Token budget | the grant's `+N` | the Workflow runtime (`budget.total`); no budget = refused |
| Concurrency | `effort.wipLimit` efforts at once (default 2), never more than 4 | the script |
| Wave reserve | 150k tokens left, or the next wave does not start | the script |
| Wave order | a wave that did not fully merge ends the run `blocked`; no later wave starts | the script |
| Stop | `stopCommand` exits 0 after a wave, or every wave merged + the gate green on the base branch | the script |

**Concurrency and the WIP limit.** Each executor runs `cckit effort start`, which refuses a new
effort once `effort.wipLimit` effort branches exist (default 2, `EFFORT_WIP_LIMIT` overrides).
`night-grant.sh` puts that limit in the args as `wipLimit` and the engine runs no wider. Three
consequences:

- A wave of 4 under the default limit runs 2 + 2, not 4 at once. Raise `effort.wipLimit` to widen it.
- An effort that parked keeps its branch, so it takes a slot from the rest of its wave; when the
  parked efforts of a wave fill the limit, the wave's remaining efforts are reported `skipped`.
- Efforts already in progress **before** the night count against the same limit, and the engine
  cannot see them. An executor whose start is refused reports that refusal as its blocker and the
  effort parks. Executors are told never to pass `--force` or set `KIT_FORCE` / `EFFORT_WIP_LIMIT`.
  Close or finish in-progress efforts before granting, or the night has fewer slots than the limit.

**Wave order.** Waves are dependency-ordered: wave N+1 builds on wave N. `cckit effort start` does
not check `blocked_by`, so the engine does: when any effort of a wave ends parked, refused or
skipped, the run returns `blocked` naming them, and no later wave starts.

**The final check is the gate.** After the last wave merges, the engine runs the gate on the base
branch and reports `done` or `blocked` on that result. `stopCommand` is a separate check that runs
after each wave and ends the night early when it exits 0; it never stands in for the gate.

**Floors.** Base floors: `lockfile`, `auth`, `security-code`, `security-prose`, `workflows`, `cost`,
`secret`. `security-prose` (a `security/*` diff that is prose only) is waived by standing rule;
`workflows`, `cost` and `secret` are never waived. A project adds its own floors, its own
never-waivable list and its gate command under `night` in the kit config (schema:
`kit.config.schema.json` § `night`):

```json
"night": { "floors": { "auth-dep": "the auth library version" },
           "neverWaivable": ["auth-dep"], "gate": "pnpm typecheck && pnpm lint",
           "grantors": ["a-maintainer"], "refuseLabels": ["hold"] }
```

A waiver must equal one floor name exactly. `"lockfile auth"` and `"*"` are refused when the grant
is read, not parked at night.

**Refused and parked.** A closed issue, an issue without the `effort` label, or an effort carrying
a label listed in `night.refuseLabels` (none by default) is refused. A red gate or a floor the grant
did not waive parks the effort for the owner. Either one ends the run after that wave.

**When it returns `usage-limit`** — an agent came back empty mid-wave. Do not relaunch. Sleep with
`ScheduleWakeup` until the window resets, then resume **one** workflow with `resumeFromRunId`.
Finished agents replay from cache; a sub whose commit already landed is never rebuilt.

**Every other stop** (`done`, `budget`, `blocked`, `refused`) — write the wake report from the
returned `efforts` (status, reason, bare PR URL each), update the one status comment on the plan
parent, and stop. A night never plans and executes the same work: only efforts the owner already
named in the grant run.

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
