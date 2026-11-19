# Claude delivery 02: one site, one entry point

PAUSED after owner review. First complete `feedback-01-revision.es.md`: the owner rejected
the sample as verbose and difficult to understand. This brief remains future scope and must
not be interpreted as permission to expand the current pattern before the sample is revised.

Read `AGENTS.md`, the local delegation/concrete rules, `README.md`, `review-01.md` and
`delivery-01.md`. Apply concrete to durable prose. Codex directs; Claude implements.
Keep evidence, commands, limitations and unresolved account requirements explicit.

## Starting state and authority

The completed local delivery is commit `84b82eb` on `task/512-docs-guides-less-text-more-visual`.
Issue 512 and PR 517 still describe the old sample. Read state through cckit before acting.
Use the existing worktree until a deliberate cckit effort transition is prepared. Never reset
the primary checkout or discard the completed commit. One writer per worktree.
Prepare the remaining work as native issues/effort according to the repository contract,
preserving the completed sample's history. Do not push, merge, deploy or create a release PR.
If a proposed tracking action would publish the branch or launch a preview, leave that action
pending and record the exact command rather than bypassing the publishing restriction.

## Goal

A visitor reaches one cckit home page, understands what connects to what, and can start learning
or look up a command. The reader no longer chooses Software versus Marketing before learning.
Profiles remain product functionality. Marketing content remains reachable as a use case.

## Implementation scope

- Inventory current routes, redirect targets, actual EN/ES sources, sidebar entries, track
  callers and locale fallbacks. Save the inventory with the delivery report before removing code.
- Unify the header and sidebar around user goals. Proposed groups: Start here, Guides,
  Concepts, Reference. Keep existing URLs where possible. Expose the delivery-01 sample.
  Put marketing guides under a use-case group; remove the track switch and routing filters.
- Build EN/ES home pages with one concrete promise, an explanatory connected visual, a clear
  start action, a route to reference, and a short guide to applying the example to one's project.
  Explain that cckit provides reusable project instructions and lifecycle commands. The coding
  agent reads those instructions and runs commands; cckit is not the coding model.
- Revise the learning visual and the factual copy identified in `review-01.md`. Keep details
  available; do not compress the entire existing reference into a landing page.
- Use Kito and friends sparingly. At desktop size the first screen should include useful
  explanation, not only a title, introductory prose and a large decorative trio.
- Correct locale handling based on genuine source translations, not `/marketing/` membership.
  Emit paired canonical/hreflang and sitemap entries for real translations, including the
  learning sample. Fallback pages keep an explicit English fallback policy and appropriate
  noindex/canonical behavior; never advertise an untranslated page as Spanish.
- Show the language control where an actual counterpart exists. Preserve links to English
  reference pages with an explicit language label when no translation exists.
- Preserve old route compatibility: record each changed URL and its final target; avoid chains.
- Fix the header's version/search overlap and the clipped brand visible in the 320px capture.
- Search must say Search/Buscar until a real Ask AI service is configured. Preserve working
  search. Do not add a simulated chat, invent an agent ID or inspect secret values.

Likely owners: `docs-site/astro.config.mjs`, `src/routeData.ts`, `src/lib/tracks.ts`, the header,
language selector, track switch and their CSS/callers, home source files, and learning components.
Confirm paths from the checkout; do not assume this list is exhaustive.
Keep dependency manifests unchanged unless a demonstrated blocker requires a separate decision.
Delivery 04 still owns the complete semantic palette; preserve accessible per-theme variants now.

## Validation

- `pnpm --dir docs-site build`; record page count, warnings and failures.
- Applicable route/Marketing checks, `scripts/update-path-test.sh`, and the required project gate.
  Run meaningful checks once after implementation; do not repeat unchanged passing gates.
- Inspect actual built HTML for EN/ES home and learning pages: language, canonical, alternate
  links, sitemap entries and fallback indexing. Test representative old URLs and reference links.
- Review desktop and 320px in both themes: readable labels, no clipped brand, overlapping header
  controls, horizontal overflow, or mandatory choice between tracks.
- Check keyboard navigation, focus, reduced motion and static content without JavaScript.
  Report unavailable browser checks rather than substituting DOM inspection for visual review.

Write `delivery-02.md`: files changed, route/locale inventory, tracking state, actual validation,
captures with route/revision/size, and remaining decisions. Update README and cckit handoff.
Do not claim deliveries 03–06 complete or release 0.10 ready.
