# Gate and review — the gate blocks the push, every reviewer finding gets an answer

Two conventions about what stands between a commit and a merge. Each was a correction the kit's
maintainer repeated across projects before it was written down; they were recorded as cckit effort
`E231` on 2026-09-07.

Complements `risk-tiered-review.md` (who reads a PR once the gates are green), `merge-safety.md`
(the gate re-run on a current base and on the integration branch) and `issue-lifecycle.md` § 2 (an
approved plan is merged without re-confirming). A profile may install only some of those; the
precedence stated under each convention applies to whichever are present.

## 1. The gate blocks the push, and the PR carries the exit evidence

**The project's gate — the one command that proves a change is sound — runs before `git push` and
blocks the push when it exits non-zero. The PR then carries that run's output and exit code.** A CI
job that runs the same command is the second observation, not the gate.

- **Origin:** a stated preference of the maintainer, repeated across projects: the gate is a
  blocking pre-push hook plus exit evidence on the PR, not a CI lint job.
- **Why not CI alone:** a CI job reports after the branch is on the remote and the PR is open for
  review. A red run then costs a fix commit, a second push and a second read of the PR. A gate
  that blocks the push fails before any of that exists.
- **Why evidence and not a sentence:** "checks pass" in a PR body is a claim. The log and its exit
  code are what a reviewer — or a captain merging unattended — can read.
- **One command.** The hook, the evidence and CI all run the same command, so a green in one means
  the same thing in the others.

**What the kit enforces, and what it leaves to you.**

| Surface | What it does | On by default? |
| --- | --- | --- |
| `prePush.enabled` + `prePush.command` in the kit config, read by `.claude/hooks/prepush_gate.sh` | a Claude Code `PreToolUse` hook on Bash: when a command contains `git push`, it runs `prePush.command` and stops the push if that exits non-zero | **No — opt-in.** `cckit init --prepush "<command>"` writes the hook and sets both keys; without the flag no profile installs it and `prePush.enabled` is `false` |
| `scripts/lib/pr-evidence.sh` — `pr_attach_evidence <pr> <file> [caption]` | posts a log (or an image) as a PR comment, one comment per caption, edited in place on a re-run | a helper, listed by `cckit lib`. No verb calls it: attach the gate's log yourself after the PR opens |
| `captain.mergePolicy.requireChecks` | `cckit watch --merge` reads a PR with **no checks at all** as `CHECKS_MISSING` → `verify` instead of green, and does not merge it | **No.** Default `false`; `KIT_CAPTAIN_REQUIRE_CHECKS=1` sets it for one run |

- **The hook gates the agent, not the terminal.** It is a Claude Code hook, not a git hook: a
  `git push` typed in a shell outside the agent session is not checked. Whoever pushes that way
  runs the gate by hand first.
- **No hook installed?** The convention still binds: run the gate, see exit 0, then push.
- **Attach the evidence** right after the PR opens:

```bash
<your gate command> > gate.log 2>&1; echo "exit $?" >> gate.log
source <cckit lib dir>/pr-evidence.sh    # `cckit lib` prints the directory and the source line
pr_attach_evidence <pr-number> gate.log "gate"
```

**Precedence — `risk-tiered-review.md` § *The gates (what "green" means)*.** That section lists a
build and a local `typecheck` + `lint` "run before push" as examples of the gates. This rule is the
stricter form and wins on *when* and *how* the gate runs: before the push, blocking, with its output
on the PR. `risk-tiered-review.md` still decides *who reads the PR* once the gate is green.
**`merge-safety.md`** adds two further runs of the same gate (on a current base, and on the
integration branch); neither replaces the pre-push run.

## 2. Every AI-reviewer finding is fixed or rebutted before the merge

**When an AI reviewer has commented on a PR, each finding is assessed before the PR merges. A
finding ends one of two ways: a commit that fixes it, or a reply on its thread saying why it is
wrong or out of scope. Silence is never an outcome.**

- **Origin — measured:** five review rounds collapsed to one when the reviewer's pass ran locally
  before the push instead of on the open PR.
- **Run the pass before the push** when the reviewer can run locally. A finding answered before the
  PR opens never becomes a thread.
- **A rebuttal names its reason** on the finding's own thread — the input the reviewer got wrong,
  the line that already handles the case, or the issue that tracks it. "Won't fix" with no reason
  is silence with more words.
- **Assess, do not obey.** A reviewer's finding is a claim to verify. Applying a wrong finding
  without checking it is the same failure as ignoring a right one.
- **A finding that recurs belongs in the gate.** A defect class that is wrong every time it appears
  becomes a `scripts/review-lint.sh` rule, so convention 1 catches it and no reviewer has to
  find it again.

**What the kit enforces, and what it leaves to you.**

| Surface | What it does | On by default? |
| --- | --- | --- |
| `review.command` in the kit config | `cckit watch --merge` pipes a brief to that command for each PR it would merge and records the verdict. A recorded `gate: fail` reads `REVIEW_FAILING` → `fix` and always blocks the merge | **No.** Unset is the off switch |
| `captain.mergePolicy.requireReview` | a PR with **no** verdict recorded reads `REVIEW_MISSING` → `verify` and is not merged | implied on when `review.command` is set, off otherwise; `KIT_CAPTAIN_REQUIRE_REVIEW=1` sets it for one run |
| `cckit status` | lists each open PR's unresolved review threads under "PRs waiting on a human" | always — a report, not a block |

- **The per-finding answer is not enforced by any verb.** The captain reads one verdict per PR, not
  one answer per thread. To make an unanswered thread block a merge, turn on *Require conversation
  resolution before merging* in the base branch's protection on GitHub.
- **Resolve a thread only after its fix is pushed or its rebuttal is posted** — resolving is what
  takes it off `cckit status`.

**Precedence — `risk-tiered-review.md`.** Its `risk:low` tier auto-passes once the gates are green,
and its § *Scope* exempts an approved plan's merges from the tiers. This rule wins over both for a
PR that carries reviewer findings: an auto-pass, and a captain merging an approved wave
(`issue-lifecycle.md` § 2), each wait until every finding is fixed or rebutted. An open finding is
not the "genuine blocker" that pings the human — the author answers it and the merge proceeds.
Everything else in `risk-tiered-review.md` stands: which tier needs a human read, and its
always-human list.
