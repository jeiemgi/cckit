# Stage: grill — one interview, a playback, a record

Input: a goal with open decisions. Output: a confirmed `## Grilling` record that
`cckit effort new` accepts.

## 1. Look the facts up first

Read the board, the code and the issues the goal touches. A question whose answer is in the repo
is never asked. Only decisions go to the owner: scope, trade-offs, order, names, cost.

## 2. One interview

Put every open question on one page, at once:

- one line per question, two or three short choices, the recommendation preselected and marked;
- an optional free-text field per question, and one at the end for what the interview missed;
- one submit: the answers come back together.

Open it as a review page when this session can show one; `cckit page mode` decides, and terminal
mode prints the same questions as one numbered message:

```bash
cckit page mode
cckit page open <interview.html> --fallback <interview.md>
cckit page poll <interview.html>
```

## 3. Play it back

Before anything is filed, answer with "what I understood": the decisions numbered, a diagram when
the plan has moving parts, and your own interpretations marked as yours. The owner confirms or
corrects. Only a confirmed playback becomes the record. An answer that opens a new question goes
into a second, smaller interview, never a lone question.

## 4. Record it

Write the confirmed record to a file in this shape:

```markdown
Grilled: <who>, <YYYY-MM-DD>, <where>.
1. <decision>
2. <decision>
3. <decision>
```

- The first line starts `Grilled:` and names who was grilled; a `YYYY-MM-DD` date is in the record.
- At least 3 decisions as column-0 `1.` items, or a link to the issue comment that holds them.
- Nothing to decide: the single line `waived: <reason>`.
- An unattended run writes `Grilled: <agent> (assumed), <date>` and lists what it assumed.

Then file it with the effort (the plan stage does this):

```bash
cckit effort new --spec-file spec.md --grilling-file grilling.md "<name>"
```

`effort new` lints the record before any forge write (`scripts/lib/grill-record.sh`) and refuses
one that names nobody, carries no date or holds fewer than 3 decisions.

## 5. Report

Write the step report in the order Status · Done · Waiting for a yes · Numbers · Failing or risky ·
Open questions · Next step (`references/step-report.md`), then post its trail comment:

```bash
cckit agent receipt <issue> --report .cckit/reports/<file>.md
```

Waiting for a yes holds the playback until the owner confirms it.
