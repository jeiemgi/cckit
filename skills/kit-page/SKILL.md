---
name: kit-page
description: >
  Open a plan, a decision with options, or a grilling round as a review page the reader answers
  (`cckit page`); print to the terminal where there is no browser; write the answer back to the
  issue or to a file.
when_to_use: >
  Before presenting a plan for approval, when the owner picks between options, or when grilling a
  plan — "show me the plan", "what are my options", "grill me". SKIP for status, a one-line
  answer, a diff, or a question with nothing to compare.
metadata:
  version: 1.0.0
---

# kit-page — a plan, a decision or a grill as a review page

Thin caller of the `cckit page` verb (`scripts/lib/review-page.sh`). The verb decides whether this
session can show a page; this skill never re-implements that check. The page tool is Lavish
(`lavish-axi`, third-party, run through `npx`), described by `integrations/lavish.json` and on by
default (`reviewPages.enabled`).

## 1. Ask whether a page can open

```bash
cckit page mode
```

- `page` — continue with step 2.
- `terminal: <reason>` — write no HTML. Print the plan, the options or the questions in the
  terminal, take the answer in the conversation, then go to step 4. This is the path in CI, an
  unattended run (`CCKIT_HEADLESS`), a headless agent session, SSH, a machine with no display, and
  a project that set `reviewPages.enabled: false`.

## 2. Write the page and open it

Read the page tool's own guidance before writing HTML — it names a playbook per kind:

```bash
npx -y lavish-axi --help
npx -y lavish-axi playbook plan        # a plan
npx -y lavish-axi playbook comparison  # a decision: options side by side
npx -y lavish-axi playbook input       # any page that collects an answer — decisions and grills
```

Write `.lavish/<name>.html`, and the same content as `.lavish/<name>.md`. Then:

```bash
cckit page open .lavish/<name>.html --fallback .lavish/<name>.md
```

`open` exits 0 either way. When the tool cannot open the page it prints the markdown instead, so
read its output: a page that did not open means the reader is in the terminal.

| Kind | What the page holds |
| --- | --- |
| `plan` | the goal, the steps in order, what is out of scope, the risks; one approve / change control |
| `decision` | the options side by side with their costs; exactly one marked recommended; one choice control |
| `grill` | one question per card, each with 2–4 options and one recommendation, plus free text |

## 3. Wait for the answer

```bash
cckit page poll .lavish/<name>.html
```

It stays silent until the reader sends feedback; run it in the foreground and do not kill it. Apply
what comes back, then poll again with `--agent-reply "<what changed>"` if the page needs another
round. End the session with `cckit page end .lavish/<name>.html` when the answer is final.

## 4. Write the answer back

```bash
cckit page answer --kind <plan|decision|grill> --title "<what was decided>" \
  --issue <issue> --body-file <answer.md>
```

The body states what was asked, what was chosen and why — in the reader's words where they gave
them. Where it lands:

| Project | Destination |
| --- | --- |
| uses GitHub (`github.repo` is set) and `--issue` is given | a comment on that issue |
| no GitHub, or no issue yet | a file `docs/answers/<date>-<kind>-<slug>.md` — commit it with the change |

`reviewPages.answers` (`issue` or `file`) fixes the destination; `reviewPages.answersDir` moves the
directory. Recording the same answer twice writes nothing the second time.

## Rules

- **Recommended, not a gate.** `cckit effort start` does not check for a page or an answer.
- **Never force a page in an unattended run.** `CCKIT_PAGES=page` is for an attended session the
  check misreads, not for autopilot or night mode.
- **Every answer is written back**, in terminal mode too. The conversation is not the record.
