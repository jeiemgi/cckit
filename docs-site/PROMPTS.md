# docs-site/ — the documentation site

The Astro site, its media and the `kit-annotate` reference. The old `docs/` folder folded in here
(#603).

| Rule | Check |
| --- | --- |
| The CLI reference lists every verb in `lib/core/verbs.tsv` | `lib/core/verbs-test.sh` |
| The site version matches the release | `release-please-config.json` extra-files; `.release-please-manifest.json` |
| No `docs/` directory comes back | `lib/core/layout-fence.sh` (top-level allowlist) |
| Nothing private is published | the leak fence in `lib/core/check.sh` |

## Editing the docs site

`docs-site/` (Astro + Starlight) has two tracks. A page under `src/content/docs/marketing/` is
Marketing; every other page is Software. The track sets the sidebar, the marker colour and the
current entry of the top-bar switch (`docs-site/src/lib/tracks.ts`, `docs-site/src/routeData.ts`).

- **Software pages live under their area.** The areas, in sidebar order: `getting-started/`,
  `project-management/`, `design/`, `development/`, `review/`, `ship/`.
  `software.mdx` is the track's entry page and `philosophy/` holds the team page beside
  `philosophy.mdx`. Reference pages (`cli-reference`, `config-and-permissions`, `integrations`,
  `skills`, `rules`, `hooks`, …) stay at the root so links to their anchors keep working. Inside an
  area the order is: why it exists, who does it, which tools plug in, the verbs, the guides. There
  is no separate tutorials section: a step-by-step page is a guide in its area.
- **The look lives in one file.** `docs-site/src/styles/theme.css` holds the palette (the Apple
  System Colors terminal scheme, dark and light), the type scale and the measured contrast ratios.
  Both tracks share one action colour; a track differs by its marker colour, `--cckit-track`. The
  typeface is Geist and Geist Mono, self-hosted through `@fontsource-variable/geist` and
  `@fontsource-variable/geist-mono`. A page opens dark when the reader has stored no choice
  (`docs-site/src/components/ThemeProvider.astro`).
- **The header is one component and never moves.** `docs-site/src/components/Header.astro` is a
  three-column grid: the wordmark, the search centred on the page, then the right group: version
  text and GitHub icon (Software only, `SocialIcons.astro`), language picker (Marketing only),
  theme picker, and the Software / Marketing switch (`TrackSwitch.astro`) last, at the right edge;
  the switch is not in `SiteTitle`. On a phone the switch, the search icon and the menu button
  share one row. Search controls take their surface and edge from `--cckit-field-bg` and
  `--cckit-field-border`, which hold 3:1 against the page in both themes.
- **The guide header is two stacked blocks** (`docs-site/src/components/TutorialMeta.astro`): the
  "Copy the prompt" banner, then "Before you start". Keep each to one line of text per item.
- **The sidebar is curated.** `sidebar` in `docs-site/astro.config.mjs` lists 43 Software pages: one
  "Start here" link, eight area groups and a Reference group, every group collapsed except the one
  holding the current page. The Marketing list is 15 pages in six groups (How it works, Get set up,
  Make a piece, Review and approve, Plan, Look things up) after a "Start here" link, nested in the
  `Marketing` entry; `src/routeData.ts` unwraps it and opens every group. Each Marketing page ends
  with a `Next:` link to the following sidebar entry; move a page and its neighbours' links move
  with it, in both languages. The sidebar group icons in `theme.css` apply to Software only. The
  site has 87 English pages (72 Software, 15 Marketing). A new Software page is not added to the
  sidebar by default: link a guide from its area's `more-guides.mdx` (`development/`, `review/`) and
  a reference page from `reference.mdx`.
- **A guide step leads with a conversation window.** `<Chat>`
  (`docs-site/src/components/Chat.astro`) shows what a person says in the agent's chat, the command
  it runs (`ran`, Software only), the real output and the agent's reply, on one running example, the
  "Bakery site". `<Outcomes>` (`Outcomes.astro`) is the collapsed block under it for outcome tables
  and exit codes. The prose says "your agent" on Software pages and "your assistant" (Spanish "tu
  asistente") on Marketing pages, and "in the chat" for the place; it names Claude Code or Codex
  only where a step is true for that product alone. Truth rule: `ran` is a real command with real
  flags, with no literal issue or task number; `output` is real (a Bakery run, a read-only verb run
  there, or a string a test in `scripts/` asserts), trimmed only with a line `…` and `<project>` for
  a path, and is omitted when none of those exists; the reply claims nothing the command did not do.
  A Marketing window carries no `ran` and no `output` (the build fails if it does). Reference pages
  stay command-first. Authoring notes: `docs-site/src/components/README-chat.md`.
- **A Marketing page has a Spanish twin** with the same file name under
  `src/content/docs/es/marketing/`. Change both in one commit. Links from a Spanish page into a
  Software page say the target is in English.
- **Marketing pages use plain words.** `astro build` fails when a page under `marketing/` or
  `es/marketing/` says "worktree", "branch" or "PR"; `words-you-will-hear.mdx` is the one
  exemption (`docs-site/src/integrations/marketing-words.mjs`, tested by
  `lib/core/docs-marketing-words-test.sh`).
- **A wide table renders as record cards.** Write a Markdown table as usual. One with three or
  more columns and a cell over 60 characters becomes a list of cards: the first cell is the
  heading, every other cell a labelled line (a leading `#` index column is folded into the
  heading). Smaller tables stay tables. To keep a grid, wrap the table in
  `<div data-table="grid">` (`docs-site/src/lib/rehype-record-tables.mjs`, tested by
  `lib/core/docs-record-tables-test.sh`).
- **`SearchStart.astro` is the search entry** on the home page and on `software.mdx`,
  `marketing/index.mdx` and `es/marketing/index.mdx`. Its chips are defined in that file, one list
  per track and language; every chip is a real link, and a script upgrades the click to open search
  with the chip's text. Check each chip's target exists when you edit the lists.
- **`tutorial.prerequisites` are full sentences.** An item is a string or `{ text, link, href }`
  (`link` is the words inside `text` that become the link; backticks make inline code), rendered as
  the checklist in `TutorialMeta.astro`.
- **No page URL changes without a redirect** in `redirects` in `docs-site/astro.config.mjs`, and
  the `expect` paths in `benchmarks/*.jsonl` follow a moved file in the same commit.
