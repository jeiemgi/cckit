---
name: page-design
description: >
  Build or change a page with three named design skills in a fixed order: impeccable (direction),
  emil-design-eng (motion), web-design-guidelines (audit). A design brief before any code, a
  self-review after.
when_to_use: >
  "build a landing page", "make a page for", "redo the homepage", "this looks generic", "it looks
  AI-made", a task of kind `page`. SKIP for copy with no layout (use copywriting), one component,
  and logo or brand work.
metadata:
  version: 1.0.0
---

# Page design

A page built here goes through three third-party design skills in a fixed order, with a written
brief before the first line of code and a written self-review after the build. This skill holds
the order, what each skill decides, and what to do when one of them is not installed. It contains
none of their content.

| Step | Skill | Decides | Made by |
| --- | --- | --- | --- |
| 1 | `impeccable` | direction: what the page is for, its type, layout and colour, and what it must not look like | pbakaus, Apache-2.0 |
| 2 | `emil-design-eng` | interaction and motion on the chosen design | Emil Kowalski, MIT |
| 3 | `web-design-guidelines` | the audit of the finished code: accessibility, focus, reduced motion | Vercel, MIT per its README |

All three are optional and installed per project: `cckit add impeccable`,
`cckit add emil-design-eng`, `cckit add web-design-guidelines`, then `cckit doctor --fix`.

## 0 · Find out what is installed, and where you are running

1. **Which of the three skills are present.** A skill is present when this session lists it, or
   one of these files exists: `.claude/skills/<name>/SKILL.md`, `.agents/skills/<name>/SKILL.md`,
   `~/.claude/skills/<name>/SKILL.md`. Check each of the three by name.
2. **Whether anyone is watching.** The run is unattended when `CCKIT_HEADLESS` is set in the
   environment, or when the prompt says so. Nobody answers a question in an unattended run.
3. **The design file.** `docs/design/<task-id>.md` when the work is a task with an id, else
   `docs/design/<page-name>.md`. The brief, the list of skills and the self-review all go in this
   one file, from `references/design-file-template.md`. It is committed with the page.

Write the `## Skills` section of the design file now: one row per skill, `present` or
`not installed`. A skill that is not installed is written as `not installed` here and stays that
way to the end. Never write that a skill was applied when it was not loaded.

## 1 · The brief, before any code

Fill the `## Brief` section of the design file. Read what the project already says first: the task
notes, `brand/voice.md`, an existing `PRODUCT.md` or `DESIGN.md`, the pages already in the project.

| Field | What to write |
| --- | --- |
| Audience | who opens this page and what they came to do, in one or two sentences |
| The one visual idea | ONE idea a person could repeat after seeing the page for five seconds. Not a mood ("clean, modern"); a thing ("the menu is the page: a single long price list, set like a printed bill") |
| Type | the families and what each is used for; why these and not the framework's default |
| Colour | the palette with values, which colour carries meaning, and what stays neutral |
| Refuses to look like | at least four concrete patterns this page will not have, picked from `references/generic-page-patterns.md`, plus any the audience would recognise as a template |

Two rules for the brief:

- **A fact you do not have is written as `not known`.** Do not invent a customer, a number or a
  brand colour. In an attended run, ask one question at a time; in an unattended run, decide from
  what the repository shows and say in the brief what you assumed.
- **The brief is written before code and not rewritten to match the result.** If the build
  departs from it, the self-review says where and why.

Commit the design file with the brief before starting the build.

## 2 · Direction — `impeccable`

**Present:** load `impeccable` and use it for direction only, in this order as the page needs
them: `init` once when the project has no `PRODUCT.md`, `shape` to plan the page before code,
then `typeset`, `layout` and `colorize` on what was built. Give each command the brief as its
input: the audience, the one idea and the refusals are already decided.

- **Never its live mode in an unattended run.** `live` and `generate` open a browser session and
  can start the agent CLI with permission checks off. With `CCKIT_HEADLESS` set, do not run
  either. In an attended run, run them only when the person asks.
- **Nobody answers `init` in an unattended run.** Take its answers from the brief. If a command
  cannot go on without a person, write that in the design file and continue with the minimum
  rules below for what it would have decided.

**Not installed:** say so in the design file (`impeccable: not installed`), then apply
`references/minimum-rules.md` § Direction. Those rules are cckit's own and are a floor, not a
replacement: the file says which skill was missing.

## 3 · Interaction and motion — `emil-design-eng`

**Present:** load `emil-design-eng` alone (not the other skills of its pack) and apply it to the
interactions and animations on the page as built. It may remove an animation step 2 added: an
animation with no purpose is removed, not tuned. Record each removal in the self-review.

**Not installed:** write `emil-design-eng: not installed`, then apply
`references/minimum-rules.md` § Motion.

## 4 · Audit — `web-design-guidelines`

**Present:** load `web-design-guidelines` and run it over the files of the page. It fetches its
rules from GitHub on every run.

- **The fetch failed, or there is no network:** write `audit: not run (the rules could not be
  fetched)` in the design file. Never write that the audit passed, and never audit from memory of
  the rules. Then apply `references/minimum-rules.md` § Audit and label the result as cckit's
  minimum checks.
- **It ran:** fix what it found. List in the self-review each finding you did not fix, with the
  reason.

**Not installed:** write `web-design-guidelines: not installed` and `audit: not run`, then apply
`references/minimum-rules.md` § Audit.

**When the three disagree, the audit wins** on accessibility and reduced motion: a contrast,
focus or motion finding from step 4 overrides a choice from step 2 or 3. Change the design, and
say so in the self-review.

## 5 · Self-review against the brief

Open the built page (run the project's dev server and load it; in an unattended run with no
browser, read the rendered markup and say that you did not see it). Then fill `## Self-review`:

1. **The one visual idea** — is it on the page? Quote where. If it was dropped, say so.
2. **Each refusal** — one line per pattern from the brief: `absent`, or `present at <file:line>`.
   A pattern that is present is fixed before the work goes to review, or listed as not fixed with
   the reason.
3. **Type and colour** — do the families and values in the code match the brief?
4. **Skills** — final state of each: `applied`, `not installed`, or `loaded, could not run:
   <why>`; and `audit: ran, N findings, M fixed` or `audit: not run (<why>)`.
5. **Not verified** — everything you could not check: not seen in a browser, no small screen
   tried, a state (empty, error, long text) not built.

Commit the design file with the page. The review names the file, so the reviewer reads the brief
beside the page.

## Rules

- **Name what was used, and only that.** The words "used", "applied" and "passed" are for a
  skill that was loaded in this session and ran. `cckit task run` reads which skills were loaded
  from the agent's own event output and prints that list in the review; a claim in the design
  file that the list contradicts is a defect in the work.
- **A missing skill is reported, then worked around.** The page is still built, with the minimum
  rules, and the design file says which skill was missing.
- **One idea.** A second visual idea is cut, not added.
- **No third-party content is copied** into the project's files or the design file: refer to a
  skill's rule by name, do not paste it.
- **To record page work** in a project with a task list: `cckit task new --kind page "<title>"`.
  The kind is what makes `cckit task run` ask for this skill and list the skills in the review.
