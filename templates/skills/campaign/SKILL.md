---
name: campaign
description: >
  Turn one marketing goal into a campaign plan, get it approved, then break it into pieces of work
  the team can take one at a time — light tasks or an effort's sub-issues.
when_to_use: >
  "plan a campaign", "we're launching X", "we need a launch plan", "what should we publish for",
  "break this campaign into tasks", "content plan for next month". SKIP to write one piece (use
  copywriting), to set the brand voice (use brand-voice), and for a single task with no plan.
metadata:
  version: 1.0.0
---

# Campaign

A campaign is one goal, one plan, and the pieces that deliver it. This skill writes the plan, gets
it approved, and records each piece as a unit of work. It does not write the pieces: `copywriting`
and the Editor do, one piece at a time, after the plan is approved.

## 1 · Read before asking

- `brand/voice.md` — the audience, the key messages and the banned phrasings are already decided
  there. If the file does not exist, say so and offer the `brand-voice` skill first; a campaign
  planned without it is planned on a guess.
- `{{PLANS_DIR}}` — an existing plan for the same goal is continued, not duplicated.
- The open work: `cckit task list`, and `cckit sync` when the project uses GitHub issues.

## 2 · The brief

Ask one question at a time, each with the answer you would propose. Stop asking when the five
lines below are filled.

| Line | Rule |
| --- | --- |
| **Goal** | One outcome and one number with a date: "120 trial sign-ups by 30 June". A goal with no number is asked for again. |
| **Audience** | One audience from `brand/voice.md`. A second audience is a second campaign. |
| **Message** | One key message from `brand/voice.md`. A message marked `unproven` there needs its proof before the plan is approved. |
| **Channels** | Where the audience already is. Each channel named here gets at least one piece. |
| **Approver** | The person who approves the plan and each piece. They need a GitHub account. |

## 3 · The plan file

Write `{{PLANS_DIR}}/{{PROJECT_SLUG}}-pm-campaign-<name>.md` from `references/plan-template.md`.
Keep the headings. The **Pieces** table is the decomposition:

- **One row per piece.** A piece is one thing a reader meets: a post, a page, an email, a brief.
- **Each piece names its one action** — what the reader does next. Two actions are two pieces.
- **Kind** is one of `post`, `campaign`, `brand`, `research`.
- **Order** is `p0`–`p3`: what must exist before something else can be written is the higher
  priority. Write the dependency in the row ("after the pricing page").
- **At most eight pieces.** More than eight is two campaigns, or a second wave planned when the
  first is done.
- **No date you were not given.** A due date comes from the person or from the goal's date.

## 4 · Approval comes before the pieces

Show the plan for approval before recording any piece — as a review page where the session has a
browser (`cckit page mode` prints `page`), in the conversation where it does not. Record nothing
until the approver says yes. Changes they ask for go into the plan file first.

## 5 · Record the pieces

Ask which list this project uses:

```bash
cckit task default        # prints: light   or: issues
```

### `light` — the task list in the project

The plan and its pieces travel in one review:

```bash
cckit task new --kind campaign "Campaign plan: <name>"
cckit task start <id>                 # prints the folder for this work
```

In that folder: save the plan file, then record one task per row of the Pieces table, **from
inside that folder** so the tasks travel with the plan:

```bash
cckit task new --kind <kind> --priority <p0-p3> --body "<channel · the one action · depends on>" "<piece title>"
```

Write each task's id into its row of the plan. Then send plan and pieces for review:

```bash
cckit task finish <id> "<name>: plan and <n> pieces" --all
```

Give the approver the link. When that review is approved and merged, every piece is on the shared
list as not started; `cckit task next` names the first one.

### `issues` — GitHub issues

One effort, one sub-issue per piece:

```bash
cckit effort new "<name>" "<piece title> :: <channel · the one action>" "<piece title> :: <…>" --kind campaign --goal "<the goal line>" --scope "<the Pieces table, one line each>" --verification "<the number and its date>"
cckit effort start <effort>
```

A title is at most six plain words, with no punctuation clauses; `effort new` refuses the whole
effort when one title fails, and creates nothing. Commit the plan file on the effort branch.
`cckit effort pr <effort>` opens the one review when the pieces are done.

## 6 · After

- Each piece is taken, drafted and sent for review on its own (`cckit task start <id>` …
  `cckit task finish <id> "<summary>" --all`, or the sub-issue flow). `--all` includes the draft
  file the piece created; without it the review opens without the draft. Fill the plan's
  `## Deliverables` row when a piece's review opens.
- When the goal's date passes, add the measured number to `## Result`. A campaign with no measured
  result is recorded as *not measured*, never as a success.

## Rules

- **One goal per campaign.** A second goal is a second plan.
- **The plan is a file, the approval is a review.** A plan that exists only in the conversation is
  lost with it.
- **Never record a piece before the plan is approved.** Unapproved pieces become work nobody asked
  for.
- **Do not write the pieces here.** This skill ends when the pieces are recorded.
