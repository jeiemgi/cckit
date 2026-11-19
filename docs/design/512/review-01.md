# Director review: delivery 01

Superseded by `feedback-01-revision.es.md` after José reviewed the screenshots. Technical
foundation retained; the sample is rejected as an entry experience. Delivery 02 is paused.

Reviewed 2026-11-19 against commit `84b82eb5573e2280744488f880281e01cc866f91`.
Decision: retain the components as an implementation foundation; revise the explanatory visual
before promoting it to the home page. Delivery 02 may proceed under `brief-02.md`.

## Evidence and limits

Read the two components, their bilingual content, the English sample, routing middleware,
header and delivery report. Inspected all three committed captures. The working tree was clean.
The report records a 215-page build and 117 passing test files; these checks were not rerun in
this review. No new browser checks were possible: Chrome DevTools reported its profile in use.
No screen-reader or cross-browser approval is implied.

## Changes before home-page reuse

1. Keep the relation rows as an expanded explanation and accessible fallback. The primary visual
   should show the five parts together with six labelled connections. Let a selection highlight
   a part and its connections without hiding the surrounding model. On mobile use a legible
   vertical arrangement; do not scale desktop text down.
2. Make the staged scene demonstrate an object changing: request, work record, isolated project,
   file change and proposed review. The current state table supports the explanation but does not
   replace it. Use labelled illustrative UI until a real demo exists; never present mock UI as
   a screenshot or command output.
3. Reduce the trio's prominence on the learning page. In the 1280x900 top capture, the first
   relationship explanation is below the initial viewport. Put the explanatory visual before
   a large decorative illustration; retain Kito and friends as supporting elements.
4. Simplify the reader's primary controls to Previous/Next plus a secondary replay/play group.
   Preserve keyboard access, pause, reduced motion and the full static explanation.

## Factual copy corrections

- `content.ts`: replace “It is the only part that writes code” / “Es la única parte que escribe
  código” with “It can edit files and run commands in your project” and its Spanish equivalent.
  A person can also edit code; cckit can write scaffolding.
- Describe this as an example workflow rather than a fixed sequence every consumer must follow.
  cckit also supports light tasks, efforts and different degrees of automation.
- Scope the claim about configured checks to this example. The beginner page need not explain
  every guard, but must not imply cckit has no built-in safeguards or that every verb runs a gate.
- Keep merge/deployment separate. Push can trigger a hosting preview before merge. Existing
  instructions still prohibit publishing/deployment; do not infer permission from this review.

## Retain

Static HTML, bilingual content, contextual terms, explicit illustration labels, optional autoplay,
reduced-motion handling, and the distinction between worktree isolation and merge conflicts.
Keep the approved reference files in git for now; their reproducibility is part of this handoff.

## Tracking

The existing issue/PR is the three-guide sample, not the complete six-delivery release. Prepare
native issue/effort tracking through cckit for the remaining scope. Preserve the existing commit
and PR history; no reset, force push, duplicate implementation or silent branch migration.
If a required transition cannot be performed, record the exact blocked operation and continue
with independent work. No new owner decision is needed merely to write a brief or prepare issues.

Concrete review: O13 avoided by distinguishing reported test results from checks performed here.
O14 resolved: rows remain as detail/fallback; a connected visual is the home-page direction.
