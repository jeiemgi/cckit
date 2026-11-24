# kit-ux-audit — the report

The report is **written, not rendered**. After the **ux** agent returns `findings.json`, author
`UX_FLOW_REPORT.html` yourself, following the **`kit-docs-writer`** skill — its page template,
voice rules, scannability mechanics, and the "before you finish" checklist. Load that skill and
hold to it. This file adds only what is specific to a UX audit report: the section order for this
content, and the visual identity.

**Not an artifact.** The report is a self-contained HTML file written into the target repo
(`<target>/UX_FLOW_REPORT.html`). Do not publish it with the Artifact tool.

## `findings.json` — the ux agent's output (the raw material)

```json
{
  "meta": {
    "target": "apps/web/src", "app": "Acme Console", "framework": "next", "router": "app-router",
    "monorepo": true, "lane": "all", "graph_source": "graphify",
    "graph_stats": { "nodes": 1840, "edges": 4120, "screens": 46, "entities": 21, "forms": 14 },
    "generated_at": "2026-09-02T18:30:00Z", "files_opened": 8,
    "visual": { "ran": false, "shots": 0, "reason": "no --visual" }
  },
  "findings": [
    {
      "id": "H3-invoice-line", "lane": "flows", "heuristic": "H3",
      "title": "5 clicks from Home to edit an invoice line item",
      "severity": "crit|p1|p2|p3", "scope": "InvoiceLine",
      "screens": ["Home", "Billing", "Billing/Invoices", "Billing/InvoiceDetail", "Billing/InvoiceLineEdit"],
      "evidence": ["shortest path: route:/ -> ... -> form:InvoiceLineForm", "no deep-link node"],
      "confidence": "high|med|low", "needs_visual": false,
      "recommendation": "One or two concrete sentences — a change, not an essay.",
      "effort_hint": "effort|quick|null", "shot": "H3-invoice-line.png"
    }
  ],
  "edit_surface_map": { "Plan": ["Settings/Billing", "Settings/Plan", "Admin/Workspace"] },
  "flow_map": [
    { "entry": "/", "screen": "Home", "depth": 0, "flags": [] },
    { "entry": "/", "screen": "Billing/InvoiceLineEdit", "depth": 5, "flags": ["deep"] },
    { "entry": null, "screen": "Tools/LegacyImport", "depth": null, "flags": ["orphan"] }
  ]
}
```

`heuristic` is `H1`–`H12` (`heuristics.md`), `C1`–`C6` (`consistency.md`), or `A1`–`A5` (`a11y.md`).
`severity`: `crit` blocks a core task or risks data loss · `p1` frequent friction · `p2` localized
· `p3` polish. `needs_visual: true` → the agent could not confirm from structure; it goes on the
"look at this" list, and if a screenshot was captured it goes inline.

## Section order (this is the `kit-docs-writer` page template, filled for an audit)

1. **Title** — `UX audit — <app name>`. Plain. No cleverness.
2. **One-line description** — one sentence: what this report tells the reader and what was scanned.
   e.g. "What in <app>'s flows, forms, and markup is likely to confuse or slow a user, found by
   reading the app's component graph rather than clicking through every screen."
3. **Run facts** — a short definition list: target path, framework/router, lane, graph source +
   node/edge counts, when it ran, how many source files were opened, whether the visual pass ran.
   If `graph_source` is `scan`, one CAUTION callout: the graph is an approximate text scan, so
   findings lean on structure — run `/graphify` for a semantic graph.
4. **The one diagram (only if it earns its place)** — a left-to-right flow of the single worst
   tangle (e.g. the deepest path, or the entity edited from the most screens). Self-explanatory
   from the title. Skip it if no single flow is worth drawing — do not draw a restated sentence.
5. **What was found** — the counts (critical / high / medium / low) and one sentence: "N findings
   across M screens." Then the findings themselves, **grouped under a heading per severity**,
   highest first. Each finding is a short block, not a card:
   - a bold lead line: the finding title
   - `Where:` the scope and the screen list
   - `Why it slows people down:` one plain sentence (define the heuristic term here the first time
     it appears, in one clause — "H6, a heavy form: many fields, most required, several steps")
   - `Evidence:` the `evidence` lines, in a code block
   - `Fix:` the recommendation, plus the `effort_hint` as "small change" / "its own effort"
   - the screenshot inline if one was captured; otherwise, if `needs_visual`, one line: "Needs a
     look at the running screen to confirm."
6. **Flow map** — the `flow_map` as an indented list from each entry route. `deep` rows show their
   click depth; `orphan` rows are pulled into a separate short list titled "Reachable only by
   typing the URL".
7. **Where each piece of data is edited** — a table: entity → every screen that writes it → count.
   Link the count to the matching H1 finding when it is 3 or more.
8. **Still to check by hand** — every `needs_visual` finding with no screenshot: the screen, what
   to look at, which finding. For the `a11y` lane, add one line: a rendered-app axe / Lighthouse
   pass is still owed — this report only reads the source.
9. **What to do next** — no dead end. Two or three concrete next steps in order: the first thing to
   fix, how to turn the rest into work (`/kit-effort-new` for a sweep, the quick lane for a
   one-file fix), and re-running the audit to verify. This is the "next-section buttons" slot.

## Voice (from `kit-docs-writer` — non-negotiable here too)

- **Zero analogies.** Describe the actual flow, never "it's like…".
- **Define every heuristic term once**, in one clause, the first time it appears.
- **Front-load.** The first words of every heading and bullet carry the meaning.
- Short paragraphs, one idea each. Lists over prose. Code and paths in code blocks.
- Callouts sparingly: CAUTION for the approximate-graph note and for any `crit` finding, NOTE for
  a beginner aside, TIP for a shortcut. Not more.
- Lead with the outcome: "Move the plan editor to one screen" beats "It would be good to consider…".

## Visual identity — the font is the protagonist

One embedded `<style>` block, no external CSS, no CDN beyond Google Fonts. Screenshots embedded as
`data:` URIs.

- **Display face: Datatype** (Google Fonts). It carries the report — the title, every section
  heading, every finding lead line, and the big severity counts are Datatype, set large, tight
  (`letter-spacing: -0.02em`), and confident. Labels (`Where:`, `Fix:`, run-fact keys) are Datatype
  in small caps / uppercase with positive tracking. This is the one memorable move; spend it here.
  Stack: `"Datatype", "Open Sans", "Helvetica Neue", Arial, sans-serif`.
- **Body face: Open Sans** (Google Fonts). All running text, `Where/Why/Fix` values, table cells,
  the flow list. Plain and quiet so Datatype stays the protagonist. Stack:
  `"Open Sans", "Helvetica Neue", Arial, sans-serif`.
- **Mono face: IBM Plex Mono** (Google Fonts). Evidence, ids, paths, code. Neutral and humanist,
  so it sits with Open Sans without competing with Datatype. Stack:
  `"IBM Plex Mono", ui-monospace, "SF Mono", "Courier New", monospace`.
- **Antialiasing.** On `body`: `-webkit-font-smoothing: antialiased; -moz-osx-font-smoothing: grayscale;`
  and `text-rendering: optimizeLegibility;`.
- **One `<link>`, three families:**
  ```html
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
  <link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Datatype:wght@400;500;700&family=Open+Sans:wght@400;500;600&family=IBM+Plex+Mono:wght@400;500&display=swap">
  ```
- **Neutrals:** a warm off-white ground with a faint bias toward the accent, not a flat grey.
- **Severity is color + word + a left rule**, never color alone: `crit` a desaturated red, `p1`
  amber, `p2` blue, `p3` slate — each defined as a token on bare `:root`. The accent (one, cool)
  is separate from the severity colors.
- **One accent moment.** Datatype at display size on the title is the anchor; everything else is
  restrained.

## Accessibility & semantic HTML (the report is a worked example)

- Full document: `<!doctype html>`, `<html lang="en">`, `<head>` with charset, viewport, `<title>`,
  `<meta name="color-scheme" content="light dark">`.
- Landmarks: one `<main>`, a `<header>` for title + one-liner + run facts, one `<section>` per
  numbered part above, each named by `aria-labelledby` → its heading, a `<footer>` to close.
  A skip link to the findings is the first focusable element.
- Headings: exactly one `<h1>` (the title); `<h2>` per section; severity groups and finding lead
  lines are `<h3>`. No skipped level.
- Right element for the content: run facts and each finding's `Where/Why/Fix` are `<dl>`; the
  severity counts, screen lists, flow map, and "still to check" list are `<ul>`/`<ol>`; the
  data-edit map is a `<table>` with `<caption>`, `<th scope="col">`, and a row header per entity.
  No `<div>` doing a list's or a table's job.
- Every screenshot `<img>` has a descriptive `alt` (finding id + title) and a `<figcaption>`; a
  decorative rule is `aria-hidden`.
- Visible `:focus-visible` on anything focusable; `prefers-reduced-motion` respected; wide blocks
  (evidence, table, flow list) scroll inside their own `overflow-x:auto` container so the page
  body never scrolls sideways.
- Theme-aware: full light palette on bare `:root`; dark overrides under
  `@media (prefers-color-scheme: dark)` guarded `:root:not([data-theme="light"])`, and again under
  `:root[data-theme="dark"]`. `body` sets an explicit token background.
- The page is fully readable with no JavaScript. If you add a severity filter, it is progressive
  enhancement over an already-complete page (real `<button type="button">`, `aria-pressed`, toggle
  the `hidden` property).

## Theme system tokens (starting point — adjust hues, keep the structure)

```css
:root{
  --bg:#f7f6f2; --surface:#fffdf8; --ink:#1a1a1e; --muted:#67675f; --line:#e7e4da;
  --accent:#3f3ac4;
  --crit:#a5322a; --p1:#8a5a12; --p2:#325f8f; --p3:#6a6a72;
}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){
  --bg:#131316; --surface:#1c1c21; --ink:#ededf0; --muted:#a1a1aa; --line:#2c2c34;
  --accent:#a6a2f4;
  --crit:#ec7d72; --p1:#e0ad60; --p2:#7fabd8; --p3:#a1a1aa;
}}
:root[data-theme="dark"]{
  --bg:#131316; --surface:#1c1c21; --ink:#ededf0; --muted:#a1a1aa; --line:#2c2c34;
  --accent:#a6a2f4;
  --crit:#ec7d72; --p1:#e0ad60; --p2:#7fabd8; --p3:#a1a1aa;
}
```

Run the `kit-docs-writer` "before you finish" checklist, then this file's accessibility list,
before you call the report done.
