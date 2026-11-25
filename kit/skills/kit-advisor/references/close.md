# Stage: close — the sprint review, the retrospective, the effort

Input: a reviewed effort, or a sprint whose week is over. Output: the review and retrospective page,
the milestone closed, the effort merged and closed with its subs.

## 1. Close the effort

Only after `cckit effort review <N>` exits 0 and the Spec items held (`references/review.md`):

```bash
cckit effort close <N>         # merge the one PR, close the parent and every sub, clean the branch
```

It refuses an effort whose parent has no checkable `## Spec`. A refusal is a fact for the report;
`--no-spec-check` is the owner's call, never the advisor's.

## 2. Close the sprint

At the end of the week, with the owner. Draft the review (what the sprint goal promised, what
shipped) and the retrospective (what to keep, what to change), then preview the page:

```bash
cckit effort sprint close --review-file review.md --retro-file retro.md --dry-run
```

The page lists the sprint goal, the issues done and the issues carried over, from the milestone.
Show it to the owner as a review page when the session can show one:

```bash
cckit page mode
cckit page open <sprint.html> --fallback .cckit/reports/<date>-sprint-<YYYY-Www>.md
```

Stop there and wait for a yes. The close writes the page and closes the milestone:

```bash
cckit effort sprint close --review-file review.md --retro-file retro.md
```

Carried-over issues stay open. Move them to the next sprint with `cckit effort sprint open` and
their milestone, or drop them from the plan; say which in the report.

## 3. Report

Write the step report in the order Status · Done · Waiting for a yes · Numbers · Failing or risky ·
Open questions · Next step (`references/step-report.md`), then post its trail comment:

```bash
cckit agent receipt <N> --report .cckit/reports/<file>.md
```

Numbers: issues done and carried over, efforts closed. Waiting for a yes: the sprint close itself,
any release, which this stage never runs, and one line per Spec item ending `(needs a yes)` in an
effort this stage closes, naming what the person must look at.
