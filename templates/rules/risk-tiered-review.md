# Risk-tiered review — spend human review only where it pays

**Human review time is the scarce resource; spend it on risky changes only.** Once the automated
gates are green, a `risk:low` PR has already passed everything a human reviewer would have checked —
re-reviewing it by hand is waste. Complements `branch-naming.md` (auto-merge, merge order, risk
labels); on a review-effort conflict, this rule wins.

## The tiering

| Tier            | Gate state                                         | Review                                                                                   |
| --------------- | -------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| **`risk:low`**  | the project's gates green (build + typecheck/lint) | **auto-pass** — the pipeline caught what a human would; `pr-automerge` lands it (squash) |
| **`risk:med`**  | gates green                                        | **human review required** — a person reads the diff before merge                         |
| **`risk:high`** | gates green                                        | **human review required** — read + reason about blast radius before merge                |

## Always-human (overrides the tier — never auto-pass)

These floor to human review regardless of the `risk:*` label, per existing rules:

- **CI / workflow changes** (`.github/workflows/**` and equivalents) — always `risk:high`; CI-token +
  supply-chain blast radius.
- **Security-touching diffs** — auth, CSP/CORS, secrets, dependency changes (a `security/*` branch is
  always `risk:high`).
- **Lockfile / dependency-graph changes** — the lockfile + package manifest (`branch-naming.md`
  lockfile rule): one in flight at a time, human-reviewed.
- **`risk:*` floors to the highest concern in a mixed PR** — never bury a risky change among trivial ones.

## The gates (what "green" means)

The gates are whatever the project runs to prove a change is sound — typically:

- **A successful build** (the deploy / build step).
- **Local `typecheck` + `lint`**, run before push.

A `risk:low` auto-pass is valid **only** when the project's gates are green. A red gate = not eligible,
no exceptions.

## Why

- An agent-driven swarm produces more PRs than a human can hand-review; uniform review is the bottleneck.
- The pipeline (build + typecheck + lint) is a deterministic reviewer for mechanical correctness — let
  it own the low-risk tier. Reserve human judgment for the changes where judgment is the actual value:
  design decisions, data/graph shape, security, blast radius.
- This is the merge-side counterpart to fanning work out across parallel agents — fan-out the work in,
  tier the review out.

## Enforcement

- `pr-automerge` already encodes the mechanism: native squash auto-merge fires **only** on `risk:low`
  PRs that aren't `blocked`/draft/`hold` (`branch-naming.md`). This rule is the **policy** that
  blesses that behavior as the default, not an exception.
- Stop an auto-pass you want a human on: add the **`hold`** label or mark the PR **draft**.
- A `risk:med`/`risk:high` PR merged without a human read is a process violation — re-tier or review.

## Scope — ad-hoc PRs, not approved-plan execution

These tiers govern **ad-hoc** PRs (a one-off change a human is about to merge). They do **not** gate
execution of an **already-approved plan**: when the captain (`kit-autopilot --plan`) drives an
approved plan, it **merges each planned wave itself** and continues — a `risk:med` change the plan
already blessed is not re-gated per-PR. The captain pings the human only on a **genuine blocker** (a
surprise always-human change not implied by the plan — see the `kit-autopilot` skill,
_Established-plan autonomy_). Don't cite these tiers to stall an approved plan.
