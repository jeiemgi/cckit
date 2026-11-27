# Issue lifecycle — deliverables, planned merges, explicit closes, emerging work

When an issue is open, who merges, what closes it, and who files new work. §§ 1–3 are corrections
the maintainer repeated across projects, recorded as cckit effort `E231` on 2026-09-07.

Complements `task-management.md`, `effort-model.md`, `plan-output-format.md` and
`risk-tiered-review.md`; each precedence below applies to whichever of them a profile installs.

## 1. A deliverable is a native sub-issue, never a body checkbox

**Every deliverable of a multi-part issue is its own GitHub issue, linked as a native sub-issue of
the parent.** A `- [ ]` list in an issue body is not tracking.

- **Origin:** issues whose deliverables were body checkboxes were closed with boxes unchecked. A
  closed issue leaves every open-issue view, so the unfinished items were lost with it.
- **Why a sub-issue fixes it:** an open sub-issue stays in every open-issue list and on the board
  after its parent closes, and the parent shows a count GitHub computes (`2/5`). A checkbox has no
  state outside its body.
- **How:** `cckit effort new "<name>" "sub :: desc" …` creates the parent and links each sub
  natively. `cckit effort close` closes the parent and every native sub-issue in one op.
- **Not covered:** a checklist that is not a deliverable — the `## Verification` checklist in a PR
  body, review steps, a reproduction recipe. Those describe one change and die with it.

**Precedence — `plan-output-format.md` § *Deliverables section*.** That table stays: it is the
plan file's index of the PRs that complete it. It is an index, not the tracker. Every row needs an
issue behind it, and when the table's `Status` column and the issue state disagree, the issue state
wins — re-read it from `gh`, then correct the table.

## 2. An approved plan is executed, not re-confirmed

**On a plan the owner already approved, the captain decides, merges each wave and continues. It
pings the human only on a genuine blocker.** The captain is whoever drives the plan: `cckit watch
--merge`, `/kit-autopilot`, or an orchestrating session.

- **Origin:** an approved plan stalled because the agent asked "merge or review?" for a routine
  planned merge, which the owner had answered by approving the plan.
- **An approved plan is** an explicit instruction to run named efforts, an approved
  `cckit effort plan`, or a wave the owner told the captain to drive. A plan the agent proposed and
  nobody approved is not one.
- **Execution means** build a wave → merge its PRs once the gate is green → close subs and parent →
  clean up → start the next wave, with a report at the end rather than a question in the middle.

A **genuine blocker** is one of these four, and nothing else:

- a merge conflict the captain cannot safely resolve;
- an always-human change the plan did not call for — a new dependency or lockfile change, an auth,
  secret or security edit, a `.github/workflows/**` edit;
- an ambiguity the approved scope is silent on;
- a destructive or irreversible step outside the plan.

A red gate is not on that list: the captain does not merge it and does not ask — it fixes the cause
or reports the failure.

**Precedence — `risk-tiered-review.md`.** Its tiers govern ad-hoc PRs; its § *Scope — ad-hoc PRs,
not approved-plan execution* says so, and this rule is the other half. For a merge the plan
covers, this rule wins: a `risk:med` change inside the approved scope is not re-gated per PR. For a
change the plan did **not** imply, that rule's *Always-human* list wins and the captain stops.

## 3. `Closes #N` links the PR; a close op closes the issue

**GitHub auto-closes an issue from `Closes #N` only when the PR merges into the repository's
default branch.** This project integrates on `develop`. Whenever `develop` is not
the GitHub default branch, a merged PR leaves its issue open, and nothing reports it.

- **Origin:** projects integrating on a non-default branch accumulated issues that stayed open
  after their PR merged, so the board showed finished work as open.
- **Beyond the board:** `cckit gc` keeps a branch whose issue is open as PROTECTED, so a merged
  branch with an unclosed issue is never offered for cleanup.
- **Close with the kit's verbs, which close explicitly:**

  | Merged with | What closes the issue |
  | --- | --- |
  | `cckit merge` / `/kit-task-pr-merge` | the op closes every issue the PR links, after the merge |
  | `cckit effort close` | the op closes the parent and every native sub-issue |
  | the GitHub UI, or a raw `gh pr merge` | nothing, off the default branch — run `cckit close <N> "<summary>"` |

- **Check:** `cckit doctor` warns when `github.baseBranch` differs from the GitHub default branch.
  After any merge the kit did not perform, read the issue state with `gh issue view <N>` — do not
  infer it from the merged PR.

**Precedence — `task-management.md`** (*PR title = issue title · body includes `Closes #N`*).
Keep writing `Closes #N`: GitHub uses it to link the PR to the issue, and the kit's merge op reads
it to find the issues to close. On whether an issue is closed, this rule wins: the keyword is a
link, the close is an explicit op.

## 4. Emerging work is filed and linked, not asked about

**Work that emerges during a sprint is filed and linked by the captain, without asking.** Filing is
not on the § 2 blocker list.

- **Origin:** captains stopped a wave to ask the owner whether to file work they had found.
- **Needed for the sprint goal:** it joins the sprint backlog — a sub-issue of the effort
  (`cckit effort sub <effort> "<name>"`) or an issue on the sprint milestone
  (`cckit new --milestone <sprint> "<title>"`).
- **Otherwise:** a new backlog item (`cckit new "<title>"`) with a `flow:` label and a
  `## Relations` line naming the effort it came from (`Extends #<effort>`).
- **Parked for later:** an open issue under no effort, with no relation, goes in Backlog so
  `cckit doctor --loose` skips it: board Status, or the `backlog` label when there is no board.
- **Ask only** when it needs a product, legal, cost or secrets decision: file it, link it, then ask
  that one question.
