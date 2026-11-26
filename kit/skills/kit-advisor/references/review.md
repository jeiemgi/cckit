# Stage: review — check each sub against its Spec

Input: an effort whose subs have landed, or claim to. Output: one verdict per sub, the gaps named,
and a decision on whether the effort is ready to close.

## 1. Read the verdicts

```bash
cckit effort review <N>        # one line per sub: state, Spec, landed, verdict; exits 1 until all are done
```

| Verdict | Means | Do |
| --- | --- | --- |
| `done` | closed, and a commit on the effort branch names it | check its Spec items below |
| `landed, still open` | the commit is there, the issue is not closed | close it once its Spec holds |
| `closed, not on the branch` | closed on the forge, no commit names it | find the work or reopen the sub |
| `open` | not built yet | back to orchestrate |
| `no spec` | nothing to review against | write the Spec with the owner first |

## 2. Check each Spec item

The verb proves a sub is closed and landed; it cannot prove the Spec holds. For each `done` sub,
read its `## Spec` and check every item against the branch: run the command an item names, read
the file it names, count what it counts. An item that cannot be checked is a defect in the Spec,
not a pass.

Then the parent: every item of the effort's own `## Spec` must hold on the effort branch, and the
gate must be green on its head commit.

## 3. Decide

- Every sub `done` and every Spec item holds: ready to close.
- A gap the effort's scope covers: send it back to orchestrate as a fix on the same sub.
- A gap outside the scope: file it as its own issue and name it in the report. Never widen the
  effort to swallow it.

## 4. Report

Write the step report in the order Status · Done · Waiting for a yes · Numbers · Failing or risky ·
Open questions · Next step (`references/step-report.md`). A Spec item ending `(needs a yes)` stays
under Waiting for a yes until the person accepts it. Then post the trail comment:

```bash
cckit agent receipt <N> --report .cckit/reports/<file>.md
```

Numbers: the `review #N: D of M done` line, Spec items checked and held. Failing or risky: every
sub not `done`, with its verdict, and every Spec item that did not hold.
