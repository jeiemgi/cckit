# Review pages — plans, decisions and grills open as a page

Three kinds of output go to a review page instead of terminal prose, because the reader has to
compare, annotate and answer:

| Kind | When |
| --- | --- |
| `plan` | before implementation: an effort's scope, a forward plan, a migration order |
| `decision` | a choice with two or more options the owner has to pick from |
| `grill` | a grilling round: the questions that stress-test a plan or an idea |

Everything else stays in the terminal: status, a one-line answer, a diff, a question with no
options to weigh.

## How

```bash
cckit page mode                        # `page`, or `terminal: <why>`
cckit page open .lavish/<name>.html --fallback .lavish/<name>.md
cckit page poll .lavish/<name>.html    # waits for the reader's feedback
cckit page answer --kind decision --title "<what was decided>" --issue <issue> --body-file <file>
```

1. **Ask first.** `cckit page mode` prints `page` when this session can show one. On `terminal`,
   write no HTML: print the plan, the options or the questions in the terminal and take the answer
   in the conversation.
2. **Write the page** under `.lavish/`, and the same content as markdown beside it. `open` prints
   the markdown when the page tool fails, so the reader is never left with nothing.
3. **Collect the answer on the page.** Options carry exactly one recommendation. `poll` returns
   what the reader sent; leave it running in the foreground.
4. **Write the answer back** with `cckit page answer`, in both modes. It comments on the issue when
   the project uses GitHub and an issue is named, and writes a file under `docs/answers/` when not —
   commit that file with the change it belongs to. An answer that lives only in the conversation
   is lost with the session.

## Limits

- **Never in an unattended run.** Autopilot, night mode, a wave pane and CI have no reader:
  `cckit page mode` answers `terminal` there, and the fallback exits 0. Do not force a page with
  `CCKIT_PAGES=page` in a run nobody is watching.
- **Other agents.** The check recognises an attended agent session by `CLAUDECODE`. An agent that
  sets no such variable and runs commands with no terminal gets `terminal`; in an attended session
  of that agent, export `CCKIT_PAGES=page`.
- **A page is recommended, not a gate.** `cckit effort start` checks for no page and no answer.
- **Off:** `reviewPages.enabled: false` in the project config (`cckit add lavish --set enable=no`),
  or `CCKIT_PAGES=terminal` for one command. With pages off, the three kinds print to the terminal
  and step 4 still applies.
- The page tool is Lavish (`lavish-axi`), third-party software run through `npx`; cckit is not
  affiliated with its author. Its own guidance for writing a page: `npx -y lavish-axi --help`.
