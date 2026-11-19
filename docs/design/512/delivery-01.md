# Delivery 01: how the tools connect

Written 2026-11-19 by Claude Code, the implementation delegate. Brief: `brief-01.md`.
Branch `task/512-docs-guides-less-text-more-visual`, on top of `889e72f`. Nothing was merged or
deployed, and nothing was pushed (see *Open decisions*).

## What exists now

| File | What it is |
| --- | --- |
| `docs-site/src/components/learning/ToolsMap.astro` | The five parts (you, your agent, cckit, your project, GitHub) as cards, and six connections as rows `from → action → to` with one sentence each. |
| `docs-site/src/components/learning/StagedScene.astro` | A numbered sequence of steps. Each step has its text, the word it introduces, a limit to keep in mind and a table of where things stand after it. |
| `docs-site/src/components/learning/content.ts` | All text of both components in English and Spanish, and the scene `smallChange` (six steps). |
| `docs-site/src/components/learning/assets/trio-approved.png` | A copy of `references/trio-approved.png` (same SHA-256, `dc1ab0bb…a78d`). Astro serves it as a 51 kB WebP. |
| `docs-site/src/content/docs/learn/how-the-tools-connect.mdx` | The English sample page, at `/learn/how-the-tools-connect/`. |
| `docs-site/src/content/docs/es/learn/how-the-tools-connect.mdx` | The Spanish sample page, at `/es/learn/how-the-tools-connect/`. |
| `docs/design/512/evidence/*.jpeg` | Three captures, listed under *Captures*. |

No navigation, global CSS, existing guide, package manifest or existing diagram was changed. No
dependency was added. Both components are Astro components with a small custom-element script;
neither uses React or React Flow.

The scene follows one change in the appointment-booking example ("each service shows how long it
lasts") through six steps: you ask, the agent records the work, the change gets a branch and a
worktree, the agent makes the change and runs the configured checks, the agent opens a pull
request, you review it. Merge and deployment are a separate section after the scene, each stated
as a decision that does not happen by itself. A last section covers a project that keeps its work
list in files (`cckit task new` / `start` / `finish`).

## Acceptance, checked

| Criterion | Result | How it was checked |
| --- | --- | --- |
| Readable static explanation before JavaScript; no canvas | Pass | In `dist/` both routes contain 5 part cards, 6 connection rows and all 6 steps with no `hidden` attribute, and 0 `<canvas>`. The controls carry `hidden` in the HTML and the script removes it. |
| Previous / Next / replay / pause reachable by keyboard, with labels and disabled states | Pass | Chrome, real key presses: Tab moved from Previous to Next, Enter and Space each advanced one step, focus stayed on the button, `:focus-visible` outline `3px solid`. Previous and "Back to step 1" are `aria-disabled` on step 1, Next on step 6. They use `aria-disabled`, not `disabled`, so the pressed button keeps focus. |
| Auto-play is opt-in, stops on interaction, respects reduced motion | Pass | Nothing plays on load. Play sets `aria-pressed="true"` and the label "Pause"; pressing Next, Previous, "Back to step 1" or "Show all steps" stops it. With `prefers-reduced-motion: reduce` emulated, Play is `aria-disabled`, a sentence says why, and the step's `animation-name` is `none`. |
| Static alternative to the stepped view | Pass | "Show all steps" lists the six steps at once; with JavaScript off that list is the page. |
| Text does not shrink to fit; stacks on narrow screens | Pass | At 320 px: no horizontal scroll (`scrollWidth` 320), no component element past the right edge, smallest text 14 px after raising the badge from 13 px. A connection row stacks top to bottom under 30rem; a step puts its state table under its text when the scene is narrower than 36rem. |
| Light and dark with visible focus and contrast | Pass, measured | See *Contrast*. |
| Decorative characters carry no facts | Pass | The trio image has `alt=""` and no text refers to it. |
| Branch, worktree and PR explained at the step that needs them | Pass | Issue at step 2, branch and worktree at step 3, commit at step 4, pull request at step 5, merge in the section after the scene. There is no glossary block at the top. |
| Truth: checks are configured, conflicts remain possible, review is not deployment, GitHub is not forced on the work list | Pass | Step 4 says cckit runs the checks the project configured and adds none. Step 3 says two changes to the same lines can still conflict. Step 5 says a pull request shows files and does not run the app. The merge section says deployment is configured apart from cckit. Step 2 and the last section name the task-file mode, and say that its review still opens a pull request on GitHub. |
| `pnpm --dir docs-site build` | Pass | Exit 0, 215 pages (213 before this delivery). |

Commands and what they printed:

- `pnpm --dir docs-site build` → `215 page(s) built`, exit 0. The one warning, `Entry docs → 404
  was not found`, is also printed without these files.
- `bash scripts/update-path-test.sh` → `ALL OK (update-path)`.
- `bash scripts/docs-marketing-words-test.sh` → `docs-marketing-words-test: all ok`.
- `bash scripts/check.sh` → `117 passed, 0 failed in 130s`, `PASS cckit check passed`. Run before the commit;
  the secret and privacy guard was run again on the staged files and exited 0.

The verbs named on the page were checked against `./bin/cckit help` and
`docs-site/src/content/docs/cli-reference.mdx`: `cckit new`, `cckit start <issue>`,
`cckit pr <issue> "<summary>"`, `cckit merge`, `cckit init`, `cckit task new`, `cckit task start`,
`cckit task finish`. The page carries no issue number and no CLI output.

### Contrast

Measured in Chrome from computed colours, WCAG 2 ratio against the element's own background.

| Pair | Dark | Light |
| --- | --- | --- |
| Body text | 9.16 | 11.35 |
| Muted text (kind, step count) | 4.85 | 5.97 |
| Status and caption text | 5.81 | 5.49 |
| Primary button text (Next) | 4.70 | 5.39 |
| Button border | 4.01 | 3.33 |
| Focus ring against the page | 7.80 | 5.62 |
| Part edge: you / agent / cckit / project / GitHub | 5.55 / 12.55 / 4.70 / 5.34 / 6.69 | 5.97 / 15.58 / 6.16 / 5.33 / 5.06 |

The brand cobalt, sage and ochre of the README do not reach 3:1 on both themes as they are:
cobalt is lightened to `#6f93ee` in dark, sage darkened to `#58733f` and ochre to `#8a6a12` in
light. These six values live in the two components' scoped CSS and are a proposal for
delivery 04, which owns the tokens.

### Captures

Taken from `http://localhost:4321/`, served by this worktree's `docs-site` (the server's working
directory was read from its process), with the delivery's files uncommitted on top of `889e72f`.

| File | Route | Size | State |
| --- | --- | --- | --- |
| `evidence/en-dark-1280x900-top.jpeg` | `/learn/how-the-tools-connect/` | 1280×900 | top of the page, dark |
| `evidence/en-dark-320x720-connections.jpeg` | `/learn/how-the-tools-connect/` | 320×720 at 2x | connection rows stacked, dark |
| `evidence/es-light-1280x900-step5.jpeg` | `/es/learn/how-the-tools-connect/` | 1280×900 | scene at step 5, light |

## Not done, and risks

- **No screen reader was run.** The step change is announced through a `role="status"` line; that
  was checked in the DOM, not with VoiceOver or NVDA.
- **Only Chrome was used.** Safari and Firefox are unchecked; the scene uses a CSS container query.
- **The trio image was checked by eye on both themes, at one size.** Its ivory outline reads on the
  dark and the light page. The pose sheets and the logo were not used and their alpha edges are
  unchecked.
- **The pages are not in the sidebar** and have no previous / next link, because the brief keeps
  navigation out of this delivery. They are reachable by address and through search.
- **Spanish routing still follows the old split.** `src/routeData.ts` removes the `hreflang`
  alternates from every page outside `/marketing/`, the language picker is shown on Marketing pages
  only, and the sitemap filter in `astro.config.mjs` drops `/es/` routes outside `/es/marketing/`.
  The Spanish sample is a real translation, and today it is missing from the sitemap and has no
  `hreflang` pair. Each page links to the other language by hand. Delivery 02 owns this.
- **The Spanish page links to four English pages** (install, initialize, light tasks, issue to
  merged) and says so beside each link.
- **The example prompt was not run.** It is the reader's own request in their own words, and the
  page shows no output for it. Delivery 03 owns running the prompts.
- **The state table is an illustration**, labelled as one in both languages. No demo app exists yet.
- **Tracked size.** `docs/design/512/references/` is about 12 MB of PNG, HTML and PDF, and the
  component copy of the trio adds 1.5 MB. If the references should stay out of git, keep only
  `manifest.json` and the one image the page uses.
- **Seen and left alone:** on the header of every page the version text overlaps the search
  shortcut hint at 1280 px. It is not caused by this delivery.

## Open decisions

1. **Push.** The work is committed on the branch and not pushed. A push updates PR 517 and makes
   Vercel build a preview of the branch. The instruction for this run was no deployment, so the
   push waits for the owner.
2. **PR 517's description** still describes the three-page word-count sample. It needs rewriting
   when the branch is pushed, and its title needs a scope and the `[#512]` token.
3. **Tracking.** Deliveries 02 to 06 are a multi-part scope with one row each in the README and no
   issue behind them. The README asks for native sub-issues and the effort lifecycle; that needs
   an effort created from #512's scope, which changes issue 512 and PR 517 and was not done here.

## Next review action

Open `http://localhost:4321/learn/how-the-tools-connect/` and its `/es/` twin, at desktop width and
at 320 px, in both themes. Decide whether the row form of the connections (no drawn arrows between
boxes) is the diagram wanted before delivery 02 puts it on the home page.
