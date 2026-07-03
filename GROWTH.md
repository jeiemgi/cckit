# Growth — SEO, analytics, distribution

Working notes for growing cckit.vercel.app. Not part of the published site. Last updated 2026-07-02.

## 1. Technical SEO — audit results

The site (Astro + Starlight) was already in good shape: `robots.txt` + sitemap present, per-page
canonical/OG/Twitter tags, a per-page generated OG image (`/og/<id>.png`), and `HowTo`/`FAQPage`
JSON-LD on every tutorial (`TutorialSchema.astro`). `/social/*` export pages are correctly
`noindex, follow` and excluded from the sitemap.

**Gaps found and fixed in this pass:**

- **No site-level structured data.** Only tutorial pages had JSON-LD. Added `SiteSchema.astro`
  (`WebSite` + `SoftwareApplication`, with repo/license/author) on the homepage — this is what lets
  Google (and AI answer engines) describe cckit correctly instead of guessing from prose.
- **No analytics at all.** Zero visibility into traffic, referrers, or which tutorial converts to
  an install. See §2.
- **No Core Web Vitals monitoring.** Added Vercel Speed Insights (see §2) — CWV is a Google ranking
  factor, and there was no way to see it.

**Left as-is (already correct):** sitemap filtering, robots.txt, canonical tags, OG images,
tutorial JSON-LD, redirect map for renamed pages. No action needed.

**Not yet actionable:** when `cckit.dev` goes live, set up a permanent redirect from
`cckit.vercel.app` → `cckit.dev` (Vercel domain redirect, not a client-side one) so backlinks and
any accumulated ranking carry over instead of starting from zero on the new domain.

## 2. Analytics — zero-cost setup (you need to do this part)

I can't create Google accounts on your behalf. Code is wired and inert until you add two env vars
in the Vercel project (Settings → Environment Variables) — same pattern as the existing Algolia
keys, no-op until set, safe to merge now.

**Why GA4 over Vercel Web Analytics:** Vercel's own Web Analytics is free on Hobby but **caps
monthly events and pauses collection once you hit the cap** — a real ceiling for a project actively
trying to grow. GA4 is free with no event cap, and pairs with Search Console for actual
keyword/impression data (which Vercel Analytics can't give you at all). Speed Insights (below) is
free-tier and covers what GA4 doesn't: real-user Core Web Vitals.

1. **GA4:** [analytics.google.com](https://analytics.google.com) → Admin → Create property →
   "cckit" → Web data stream → `https://cckit.vercel.app`. Copy the Measurement ID (`G-XXXXXXX`).
   Set `PUBLIC_GA_MEASUREMENT_ID` in Vercel.
2. **Search Console:** [search.google.com/search-console](https://search.google.com/search-console)
   → Add property → URL prefix → `https://cckit.vercel.app` → verify via "HTML tag" method → copy
   the `content="..."` value. Set `PUBLIC_GSC_VERIFICATION` in Vercel. Submit
   `https://cckit.vercel.app/sitemap-index.xml` in Search Console once verified — this is your main
   window into "what people actually search that lands on cckit," which should directly feed §3.
3. **Speed Insights:** already wired (`@vercel/speed-insights`, `<SpeedInsights />` in the Footer
   override) — nothing to configure, it activates automatically once deployed on Vercel.
4. Redeploy after setting the env vars (or trigger one from the Vercel dashboard).

## 3. Keyword / content strategy

The site already does the hard part right: every tutorial title is phrased as a real search query
("How to set up cckit in a Git repo", "Stop Claude Code from committing secrets") answered in the
first screen — this is the single highest-leverage SEO pattern for a docs site, keep doing it for
every new capability.

**Primary terms cckit can realistically rank for** (low-to-medium competition, high intent):

- `claude code github workflow`, `claude code issue to pr`, `run claude code in parallel`
- `claude code worktree`, `claude code unattended` / `claude code overnight`
- `stop claude code committing secrets`, `claude code persistent memory`
- `agentic github workflow cli`, `ai coding agent project management`

**Content gaps worth filling** (each becomes one more page targeting one more query):

- A comparison/positioning page: "cckit vs. GitHub Copilot workspace / Devin / plain Claude Code" —
  people actively search comparisons before adopting a tool; you currently have none.
- A "Claude Code slash commands cheat sheet" or similar reference page — high-search-volume generic
  term you could rank for as a side effect of documenting your own skills.
- Case-study framing: "cckit builds cckit" is already in the README — turn it into a docs page with
  screenshots of real merged PRs. Real receipts outrank marketing copy for this audience.
- FAQ schema is only used on tutorials — a dedicated FAQ section (or expanding `philosophy`/`index`
  with FAQ entries) targets the "People also ask" boxes on Google directly.

**Long-tail, low effort:** each tutorial's `keywords:` frontmatter field already exists
(`content.config.ts`) but is undocumented as a growth lever — treat it as your target-query list per
page and revisit it once Search Console gives you real query data (§2).

## 4. Distribution / backlinks

For a brand-new domain, backlinks and community placement matter more than on-page tweaks — Google
has very little to go on yet besides who links to you. In priority order:

1. **`hesreallyhim/awesome-claude-code`** (45k stars, the canonical list) — currently mid-restructure
   ("new organizational system in progress" per their README as of today). Check their
   `CONTRIBUTING.md` / `templates/` for the current submission format before opening a PR; a listing
   here is the single highest-value backlink+traffic source available.
2. **`ComposioHQ/awesome-claude-plugins`** and **`rohitg00/awesome-claude-code-toolkit`** — actively
   maintained, lower bar, both take PRs.
3. **`quemsah/awesome-claude-plugins`** — auto-discovers public repos, no submission needed, but
   confirm cckit shows up (it indexes within hours of being public).
4. **Claude Code plugin marketplaces** — the official plugin marketplace docs
   ([code.claude.com/docs/en/plugins-reference](https://code.claude.com/docs/en/plugins-reference))
   list how a plugin gets discovered there; cckit already ships a `.claude-plugin` manifest, so this
   is close to a free listing given the manifest exists.
5. **Show HN** (news.ycombinator.com) — a well-titled "Show HN: cckit — the full GitHub work
   lifecycle as a CLI for Claude Code" post, timed for a weekday morning US time, is a proven
   traffic+backlink spike for exactly this kind of dev tool.
6. **Product Hunt** — works best paired with a specific launch moment (e.g. the `cckit.dev` domain
   going live, or a notable release like the v0.4.0 you just tagged).
7. **r/ClaudeAI, r/ClaudeCode, r/commandline** — share as "here's what I built," not an ad; this
   audience penalizes anything that reads as marketing.
8. **GitHub repo topics — currently empty, 30-second fix.** Add topics like `claude-code`,
   `ai-agents`, `cli`, `developer-tools`, `github-workflow`, `agentic-coding`, `llm-tools` in repo
   Settings. This is free discoverability on GitHub's own topic pages and search, and costs nothing.
9. **The existing "Built with cckit" badge is already a backlink growth loop** — every adopter who
   adds it links back to the GitHub repo. Consider also linking the docs site
   (`https://cckit.vercel.app`) from the badge, not just the repo, so adopters drive traffic to the
   page that actually converts visitors (the tutorials), not just the source.

## What's implemented vs. what's on you

| Done in this PR | Needs you |
| --- | --- |
| Site-level JSON-LD (`SiteSchema.astro`) | Create the GA4 property + Search Console verification, set the two env vars |
| GA4 + Search Console wiring (env-gated, no-op until set) | Submit sitemap in Search Console once verified |
| Vercel Speed Insights (auto-active) | Add GitHub repo topics (5 min) |
| This growth doc | Submit to awesome-lists / Show HN / Product Hunt (§4) — timing and framing are yours to call |
