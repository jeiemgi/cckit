# Docs experience: execution checkpoint

Updated 2026-11-19, after delivery 01. Owner: José. Director/reviewer: Codex. Implementation delegate: Claude Code.

## Resume here

Worktree: `.claude/worktrees/task+512-docs-guides-less-text-more-visual`.
Branch: `task/512-docs-guides-less-text-more-visual`.
Issue: <https://github.com/jeiemgi/cckit/issues/512>.
PR: <https://github.com/jeiemgi/cckit/pull/517>.
Starting head: `889e72f25d8fca89f1676bfa595abd29b77d6e15`.
Base: `develop`, observed at `b22039057e9eec30294a2b53224b61e98889ed28`.

The existing PR changes three guide files. It does not implement the scope below.
Its old word-count acceptance criterion is superseded by comprehension, factual completeness,
and visual explanation. Do not remove facts or hide prerequisites to meet a word count.

Delivery 01 is implemented and committed on this branch, not pushed: read `delivery-01.md` for
the files, the checks that ran, the risks and three open decisions (push, the PR description, and
native sub-issues for deliveries 02 to 06). Delivery 02 is next and has no brief yet.

`brief-01.md` is the brief delivery 01 was built from. Only one writer may use this worktree at a time.
Run subsequent deliveries sequentially here, or create native issues/worktrees through cckit
for independent changes. A multi-issue effort requires the effort lifecycle and one parent PR.
The table below records delivery order; it is not a substitute for native sub-issues.

## Approved decisions

- One site and navigation. Replace the Software/Marketing split with user goals and use cases.
  CLI profiles continue to exist; removing a navigation switch does not remove a profile.
- Explain cckit to someone who has chatted with a coding agent but may not know Git.
  Start with how the agent, cckit, project files/rules and GitHub connect.
- Use a small appointment-booking app as the recurring reference project. Readers apply
  prompts to their own project. Do not require building the demo to learn cckit.
- Five onboarding chapters: connect the tools; set up an existing project; define a small
  change; make and review it; resume another day. Teach efforts and waves later.
- English and Spanish are the target for the complete site, including reference pages.
  Inventory missing translations and ship real translations; an English fallback is not one.
- Define repo, issue, worktree, PR and merge when they become relevant. Keep a small glossary.
- Explain with consistent diagrams, staged illustrations, prompts, annotated screenshots
  and demo states. Use precise diagrams for behavior; use mascots as supporting illustration.
- Essential prerequisites and the next action stay visible. Expanders hold optional internals.
- Use Geist for interface and reading text and Geist Mono for code. The approved logo uses
  sober geometric lowercase lettering; the earlier comic lettering was rejected.
- Respect explicit light/dark choices and reduced motion. Document semantic colors,
  responsive layout, focus/hover/disabled/error states and readable type sizes.

## Character and asset contract

Kito is a terminal window. Kito is not a keyboard K, bracket, or folded-paper character.
Friends: an ochre Post-it represents a ticket; a sage USB stick represents memory.
Style: flat developer-sketchbook illustration, felt-tip outlines, small offset printing,
sparse halftone dots and hatching. No cape, 8-bit treatment, or comic logo font.

| Role | Color |
| --- | --- |
| Ivory | `#F2F4EB` |
| Forest charcoal | `#202521` |
| Cobalt | `#2457D6` |
| Sage | `#8FA878` |
| Ochre | `#D4AF59` |

These are brand colors, not a verified semantic UI palette. Test contrast for each use.
Kito has a broad cobalt frame, charcoal screen, three ivory title-bar circles, `>_`,
ivory oval eyes and mouth, thin limbs and charcoal shoes. The ticket has two checkboxes,
wavy lines and a curled lower-right corner. The USB has a two-hole ivory USB-A connector.

`references/trio-approved.png` and `references/cckit-logo-approved.png` are the approved masters.
The three pose sheets guide continuity. Reuse these assets for exact repeatability; no image
generation seed is available. Check their alpha edges against both themes before production use.
`references/manifest.json` records source filenames and SHA-256 values.

`research-proposal.es.md` preserves the earlier research verbatim. This README supersedes its
older logo status. The earlier identity PDF includes a rejected logo and is not copied here.
The wireframes preserve exploratory layout; they are not a completed implementation.

## Delivery order and review criteria

| Delivery | Scope | Evidence required | State |
| --- | --- | --- | --- |
| 01 | Reusable tools diagram and staged scene, one EN/ES sample | Keyboard controls, reduced motion, correct lifecycle, build | Implemented, awaiting review: `delivery-01.md` |
| 02 | Unified navigation, home, language routing and redirects | Route inventory; no broken links or false translations | Pending |
| 03 | Five-chapter EN/ES onboarding and appointment demo story | Run prompts; preserve setup preconditions and error recovery | Pending |
| 04 | Light/dark tokens, typography, layout and mascot placement | Mobile/desktop review; contrast and UI-state samples | Pending |
| 05 | Reference inventory, translations, glossary and remaining guides | Page-by-page fact/translation map | Pending |
| 06 | Real search/Ask AI integration when account config is available | Answers cite docs; search fallback; no simulated chat | Pending |

Do not claim the complete release is ready when only delivery 01 passes.
Screenshots/GIFs must come from a real, named demo state, not an invented interface.
Record their route, revision and capture size. Animation needs replay/pause and a static alternative.

## Technical findings to preserve

- `docs-site/` uses Astro/Starlight, React and React Flow. Dependencies are already present.
- `src/lib/tracks.ts`, `src/routeData.ts`, `Header.astro` and `LanguageSelect.astro`
  enforce the current split. Inventory their callers before changing the routing contract.
- `ThemeProvider.astro` forces dark without a stored preference. Review its behavior against
  explicit user choice and system theme before changing it.
- `Chat.astro` and `TutorialMeta.astro` contain track-specific language and Bakery defaults.
- Existing React Flow diagrams can scale text too small. A staged scene should remain readable
  at 320px and keep behavioral text available without hydration.
- An issue and a light task are different modes. Checks depend on project configuration.
  A PR reviews files; an app preview runs software; merge and deployment are separate actions.
  Worktrees isolate files but do not guarantee conflict-free merges. An effort has one parent PR.
- Existing “Search or ask” chips only open search. Installed `starlight-docsearch` 0.8 resolves
  DocSearch 3.9. Agent Studio Ask AI needs a compatible integration and account configuration.
  Do not advertise chat until it actually answers. Do not inspect or print secret values.
- `astro.config.mjs` currently excludes most Spanish routes from sitemap; preserve the
  distinction between real translations and fallbacks while revising locale behavior.

## Validation and transport limits

Run `pnpm --dir docs-site build` for docs changes, applicable docs word/link checks,
and `bash scripts/update-path-test.sh` when links or paths change. The project-wide gate is
`bash scripts/check.sh`; report checks actually run and their results, including failures.
Review the changed screen on the existing server at <http://localhost:4321/>; old docs run at
<http://localhost:4322/>. Verify which checkout each server serves before trusting it.

On 2026-11-19 `./bin/cckit sync --llm` failed because terminal access to api.github.com and writes
to `.git/kit-events.jsonl` were denied. The connected GitHub app can read repository state.
Claude Code 2.1.328 is installed. The first delegated run was launched through cckit and stopped
with `agent-failed` after ten API retries. Its final error was:
`API Error: EPERM: operation not permitted, mkdir '~/.config/anthropic/credentials.lock'` (home directory shortened).
No implementation files were created. This is a denied credential-lock write, not evidence that
Claude needs a new login. Do not copy credentials, change their location, or bypass the sandbox.
The runner PID 20324 no longer exists. A fresh run can start in a normal terminal that has the
required access. The connected GitHub app also rejected converting PR 517 to draft with
`Resource not accessible by integration`; PR 517 remains open and not draft.
Never reset the primary checkout.

Delivery 01 was then built on 2026-11-19 in an interactive Claude Code session started in a normal
terminal, with no new login. The command below was not used and is kept as the record of how the
first attempt was launched:

```sh
./bin/cckit autopilot run 512 --fresh --agent claude \
  --prompt-file docs/design/512/brief-01.md \
  --max-iters 1 --max-seconds 900 --round-seconds 900 \
  --agent-arg --permission-mode --agent-arg acceptEdits --record-skills
```

`acceptEdits` permits file edits; it does not grant every shell tool call. A denied build command
must be reported for the director to run. The command does not publish, merge or deploy.

Before stopping, update this file with actual results and run `./bin/cckit handoff` with the
remaining delivery, next command, branch and references. If that write fails, preserve the same
information in this tracked directory and state the failure explicitly.

## Results of delivery 01

Run on 2026-11-19 in this worktree; details and limits are in `delivery-01.md`.

- `pnpm --dir docs-site build`: exit 0, 215 pages (213 before).
- `bash scripts/update-path-test.sh`: `ALL OK (update-path)`.
- `bash scripts/docs-marketing-words-test.sh`: all ok.
- `bash scripts/check.sh`: `117 passed, 0 failed`, `PASS cckit check passed`.
- Browser review in Chrome on `http://localhost:4321/` (served by this worktree): keyboard
  controls, reduced motion, 320 px and 1280 px, light and dark, contrast measured.
- Not run: a screen reader, Safari, Firefox.

## Prose review

Concrete review: claims about implementation and validation are marked pending rather than
presented as complete (O13); the selected identity and site architecture are stated as decisions,
while account-dependent Ask AI remains conditional (O14). Evidence and limits are retained.
