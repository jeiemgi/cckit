# Stage: orchestrate — start the effort and brief the workers

Input: a planned effort (subs filed with Specs, wave order checked). Output: one worktree per
worker, each started with a brief that names its exact toolset, and the effort branch collecting
the landed subs.

## 1. Start the effort

```bash
cckit effort start <N>        # effort/<N>-<slug> branch + its own worktree, from the base branch
```

The effort branch is the one integration branch. Sequential subs commit on it, one commit per sub.
Parallel subs each get their own worktree cut from it and merge back in. The WIP limit refuses a
new effort while too many are open; that refusal is a fact to report, not a reason to `--force`.

## 2. Pick the wave

```bash
cckit effort plan --wave --effort <N>     # the subs that can start now, file-disjoint
```

Run only the first wave. Subs that touch the same file go in different waves, even when the plan
had them parallel: two workers on one file is a conflict waiting at merge time.

## 3. Brief each worker

```bash
cckit brief <sub> --skills kit-ship --verbs 'effort start,status,agent receipt'
```

One brief per sub. `--skills` and `--verbs` name the tools the worker may use, and only those: an
unknown name exits 2 before anything is read, so fix the list instead of dropping the flag. The
brief carries the worktree, the files the sub owns, the helpers they sit on, the gate and the
standing gotchas, so the prompt adds the sub's Spec and nothing the brief already says.

Each worker works in its own worktree, never in the shared checkout, and ends with its own step
report and trail comment on its sub.

## 4. Collect the wave

As each worker reports, read its trail comment, check the sub's commit is on the effort branch,
and start the next wave from `cckit effort plan --wave --effort <N>`. A worker that stopped on a
decision goes to the owner; a worker that stopped on a broken verb is a kit defect to file.
Work a worker found outside its sub is filed and linked, not asked about (`issue-lifecycle.md`
§ 4): a sub-issue of the effort if the sprint goal needs it, otherwise a backlog item with a
`flow:` label and a relation to the effort.

## 5. Report

Write the step report in the order Status · Done · Waiting for a yes · Numbers · Failing or risky ·
Open questions · Next step (`references/step-report.md`), then post its trail comment:

```bash
cckit agent receipt <N> --report .cckit/reports/<file>.md
```

Numbers: workers started, subs landed, waves left. Failing or risky: any sub whose gate is red, and
any two subs that turned out to share a file.
