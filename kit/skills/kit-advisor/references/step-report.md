# Step report — one order for every stage

Every advisor stage ends with one report file and one trail comment.

## Where

`.cckit/reports/<YYYY-MM-DD-HHMM>-<effort>-<stage>.md`, for example
`.cckit/reports/2026-11-24-1430-E547-plan.md`. `.cckit/` is local and not committed unless the
effort asks for its report in the PR.

## The order

The sections are always these seven, in this order: Status · Done · Waiting for a yes · Numbers ·
Failing or risky · Open questions · Next step. A section with nothing to say says `none`; it is
never dropped, because an absent section reads like a passing one.

```markdown
# <effort> · <stage>

## Status
One to three lines: what is true now. The trail comment quotes this section.

## Done
What this stage changed, one row per artifact (issue, commit, page, file).

## Waiting for a yes
The decisions only the owner can make, numbered, each with the recommendation first.

## Numbers
| Measure | Before | After | Command |

## Failing or risky
A red check, a guess, a step not verified.

## Open questions
What the stage could not settle and nobody has been asked yet.

## Next step
The one next action and who takes it.
```

## The trail command

```bash
cckit agent receipt <issue> --report .cckit/reports/<file>.md            # post or update
cckit agent receipt <issue> --report .cckit/reports/<file>.md --dry-run  # print, do not post
```

(`cckit receipt` is the old name and still works.) The comment carries the Status head, the
report's links and the Waiting for a yes items, capped at 1500 characters. It refuses a report that
holds a word from the private leak list or an absolute home path, so write paths relative to the
repo.

## Rules

- Numbers come with the command that produced them. A number without one is a guess; put it under
  Failing or risky.
- Waiting for a yes lists decisions, not mechanics. Merging a PR whose content was decided is
  mechanics.
- One report per stage run. A re-run of the same stage rewrites its file, and the trail comment is
  edited in place, not posted twice.
