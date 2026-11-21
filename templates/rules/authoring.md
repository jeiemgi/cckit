# Authoring — docs in the same change, prompts without issue numbers, summaries a person can read

Three conventions about what gets written alongside the work: the docs, the prompts in those docs,
and the summary handed back to a person. Each was a correction the kit's maintainer repeated across
projects before it was written down; they were recorded as cckit effort `E231` on 2026-09-07.

Complements `communication-style.md` (format, length, the `concrete` pass on durable prose),
`naming-and-ids.md` (the `E241` / `#209` / `PR 268` tokens), `plan-next.md` (the docs step in a
forward plan) and `effort-model.md` (efforts render as `slug #N`). A profile may install only some
of those; the precedence stated under each convention applies to whichever are present.

## 1. Docs and README are acceptance criteria, never a follow-up

**A unit of work is not done until the docs it makes untrue are corrected, in the same change.**
The unit is whatever lands as one reviewed diff: a task PR, or one sub-issue's commit on an effort
branch.

- **Origin:** a stated rule, not an incident — the maintainer made it mandatory that every proposed
  or shipped unit of work updates the docs and the README, small changes included. Until this rule
  it was written down only for `plan-next` output (`plan-next.md` § *The mandatory docs + README
  step*), a rule no profile ships.
- **What "the docs" means:** every place that states the behaviour the change alters. In most
  projects that is the `README.md`, the agent contract (`CLAUDE.md` / `AGENTS.md`) and the matching
  page of the docs site or knowledge base. Find them by searching for the verb, flag, config key or
  path the change touches; a match the diff leaves stale is unfinished work.
- **In the issue:** the acceptance criteria of an issue that changes behaviour name the doc
  updates. An issue that omits them still owes them.
- **In review:** a behaviour change whose diff touches no doc is incomplete. The fix is the doc
  edit in that PR, not a new issue.
- **What does not count:** "docs to follow" in a PR body, and a docs issue filed to be picked up
  later. Both leave the base branch describing behaviour it no longer has.
- **When there is nothing to update:** a change with no user-visible or agent-visible behaviour
  (an internal rename, a test) owes no doc edit. Say so in the PR body in one line, so the reviewer
  reads a decision and not an omission.

**Precedence — `plan-next.md` § *The mandatory docs + README step*.** That section puts a docs +
README step at rank 1 of every forward plan and requires the effort scoped from it to keep a docs
sub-issue. This rule wins on where a sub's own docs go: each sub-issue updates the docs its change
alters, in its own commit, and does not defer them to the docs sub-issue. The docs sub-issue stays
for what no single sub owns — an overview, a tutorial, an index page. `plan-next.md` still wins on
the plan's shape: the step is in every plan it emits.

**Precedence — `communication-style.md` § *Durable prose*.** That section governs how a doc is
worded; this rule governs whether it is written. They do not conflict.

## 2. A prompt in a doc never hardcodes an issue number

**A prompt the reader is meant to paste — in a tutorial, a README, a runbook, an onboarding page —
tells the agent to read the board and lets the human pick the work.** It carries no literal issue
number.

- **Origin:** a correction. Tutorial prompts shipped with literal numbers, of the form
  `cckit orchestrate 46 47 48`. Those numbers were issues in the author's repository on the day the
  page was written; in the reader's repository they are other issues, closed ones, or nothing.
- **Write instead:** *sync the board, show me what is ready, and I will pick.* The agent runs
  `cckit sync`, presents what is unblocked, and the person chooses. Which lane the choice goes to —
  one issue, an effort, a wave, an unattended run — depends on what was picked, so the prompt does
  not fix that either.
- **In a command line:** a placeholder (`cckit start <issue>`, `cckit orchestrate <issues…>`) or a
  form that selects for itself (`cckit next`, `cckit autopilot --cap 2`).
- **Verify the verbs.** A prompt is run as written. Check each verb and flag against the CLI
  reference before the page ships; a prompt naming a verb that does not exist fails on the reader's
  first paste.

This binds prompts and tutorials, which are instructions for a repository the author has not seen.
It does not bind a record — a commit message, a PR body, a changelog, an ADR — which cites the real
number because it describes one repository's history. An example that illustrates a format (the
`E241` in `naming-and-ids.md`) is not a prompt either.

**Precedence — `naming-and-ids.md`.** That rule decides how a reference is written when there is
one. This rule decides that a pasted prompt has none. For a prompt, this rule wins; everywhere else
`naming-and-ids.md` stands.

## 3. A human-facing summary names the work and carries no machine-flag decoration

**A summary written for a person — a status recap, a hand-off, the end-of-task report — leads with
the name of the work and its outcome.** Two parts:

- **No machine-flag decoration.** Do not attach an output-mode variant to a verb you are only
  mentioning: `cckit sync --llm`, `--output=json`, `--porcelain`. The flag tells the reader how a
  program would parse the output, which is not something they asked.
- **Name the work, with its number.** An effort is written `slug #N` — `auth-hardening #42` — the
  form `effort_display` prints in the kit's own listings. A bare `#42` makes the reader look the
  issue up to learn what it is.

- **Origin:** a correction. Recaps carried `cckit … --llm` beside each verb they mentioned, and the
  maintainer's response was that the tags said nothing and were not visually useful. The same
  correction asked for efforts to be named `slug #N` and not by number alone.
- **A command still belongs in a summary when the reader runs it next.** Then it is written
  exactly as it should be typed, flags included. The test is whether the reader will execute the
  line; a command listed to show what the agent ran is decoration.
- **Scope:** text a person reads. Output an agent parses, a brief handed to a sub-agent, and the
  machine-read lines `naming-and-ids.md` lists (`- Depends on #N`, `Closes #N`) are not summaries.

**Precedence — `naming-and-ids.md`.** That rule writes an effort as `E241`, a pull request as
`PR 268` and a standalone issue as `#209`, and forbids a bare `#241` for an effort. Where it is
installed, it wins on the identifier: write `E241`, not `#241`, and `PR 268`. This rule wins on the
name: `naming-and-ids.md` adds the name on first mention "if the reader needs it"; in a summary the
first mention always carries it — `E241 auth-hardening`, `#209 the pr-merge cleanup fix`. Where
`naming-and-ids.md` is not installed (no profile ships it), `slug #N` is the form.

**Precedence — `communication-style.md`.** That rule sets format and length (bullets, tables,
short). This rule adds what a summary must name and what it must leave out. Its § *Durable prose*
sends commits and PR bodies through `concrete`, which treats flag names as evidence that is never
cut. That stands: a flag that is evidence — the command that was run and its exit code in a PR
body — stays. This rule removes only the flag attached to a verb the text merely mentions.
