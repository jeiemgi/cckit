---
name: kit-ux-audit
description: Expert UX/UI audit of a front-end app, driven by a component/screen graph instead of a screen-by-screen walkthrough. Three lanes over one graph and one report — flows (routes ↔ screens ↔ containers ↔ components ↔ data entities ↔ forms; a UX agent runs 12 heuristics to surface confusing or erratic flows: the same data editable from many screens, deep paths to frequent actions, orphan/dead-end screens, heavy forms, structurally inconsistent patterns, overloaded screens, unguarded deletes, nav-away data loss), consistency (deterministic design-system pass: hand-rolled UI, className overrides on shared primitives, sibling-screen layout drift, variants-in-disguise, dead CSS — the model only classifies), and a11y (semantic-HTML + accessibility: non-semantic interactive elements, missing text alternatives, unlabeled controls, heading/landmark gaps, focus and keyboard problems). Emits a self-contained, accessible HTML report. Use AUTOMATICALLY when the user asks for a UX audit / UX review, to analyze app flows or navigation, to find where a piece of data can be edited, to check form usability, to review information architecture, to find confusing / hard-to-fill screens, for a design-system consistency pass / DS audit / "is this page consistent" / "what should be a variant" / "find hand-rolled solutions", OR for an accessibility / semantic-HTML review / "is this markup accessible" / "find non-semantic divs". Optional graphify integration; falls back to a dependency-free deterministic scan. Visual verification (Playwright / Chrome screenshots) is opt-in via --visual.
when_to_use: Before a redesign, after a feature that added screens or forms, when users report "I can't find where to change X" or "there are too many places to edit this", before scoping a UI refactor effort, or on demand for an IA / flow / consistency / accessibility health check. Targets component front-ends (Next.js, React Router v7, Vite React, Vue). For a purely visual per-screen critique of a running app, use a visual design-critique skill instead — this one reasons over structure. The a11y lane is a source-level check, not a substitute for axe / Lighthouse against the running app.
argument-hint: "[--lane flows|consistency|a11y|all] [--path <dir>] [--app <name>] [--visual] [--rebuild-graph] [--primitives <index.ts>] [--css <theme.css>] [--css-prefix <p>] [--dry-run]"
allowed-tools: Bash, Read, Write, Glob, Grep, AskUserQuestion, Task, Skill
---

# kit-ux-audit — graph-driven UX/UI audit

Analyze how a front-end app's **flows, data-editing surfaces, forms, and design-system usage** hang
together by reasoning over a **graph** of the app — not by opening screen after screen. Two lanes,
one graph, one HTML report. Detection is deterministic (a script / the graph); judgment is the
model. Never eyeball a codebase for something a script already finds — run it, read it, then think.

| Lane | What it does | Detector | Judge | Heuristics |
| --- | --- | --- | --- | --- |
| `flows` (default) | Confusing / erratic flows, IA, edit surfaces, forms | graph (graphify or fallback scan) | **ux** agent | `references/heuristics.md` (H1–H12) |
| `consistency` | Design-system consistency: hand-rolled UI, primitive className drift, sibling-screen drift, variants-in-disguise, dead CSS | `scripts/ux-ds-audit.sh` | **ux** agent → routes decisions to designer/frontend | `references/consistency.md` (C1–C6) |
| `a11y` | Semantic HTML + accessibility: non-semantic interactives, missing text alternatives, unlabeled controls, heading/landmark gaps, focus/keyboard | `scripts/ux-a11y-scan.sh` | **ux** agent | `references/a11y.md` (A1–A5) |
| `all` | All three lanes, merged into one report | all | | all |

Kit lives at `${CLAUDE_PLUGIN_ROOT}`. Engines:
- `scripts/ux-graph-scan.sh` — `--apps <root>` (enumerate app-like packages) · `--scan <dir>`
  (deterministic, dependency-free flows graph: routes, renders, nav, data reads/writes, forms).
  No LLM, no API key. Sources `scripts/lib/react-detect.sh`.
- `scripts/ux-ds-audit.sh` — deterministic design-system occurrence lists (grep/perl, macOS-safe).
  Parameterized: `--primitives <ui-barrel>` `--css <theme.css>` `--css-prefix <p>` — so it runs
  against any design system, nothing hardcoded.
- `scripts/ux-a11y-scan.sh` — deterministic semantic-HTML / accessibility smell lists (grep/perl,
  macOS-safe). No parameters beyond `--exclude`.

There is **no report renderer**. The report is written by hand from `findings.json` following the
`kit-docs-writer` skill — see `references/report.md`.

References — load only when you reach the step that needs one:
- `references/graph-model.md` — normalized node/edge model; how graphify `graph.json` and the
  fallback scan both map onto it; how to derive click-depth / god-nodes / community bridges /
  edit-surface map.
- `references/heuristics.md` — the 12 `flows` heuristics: graph signal, default severity, whether
  the finding needs visual confirmation. **This is the flows audit.**
- `references/consistency.md` — the `consistency` lane: the `ux-ds-audit.sh` sections, the
  LAYOUT / VISUAL / BEHAVIOR classification, sibling-screen comparison, variant proposals.
- `references/a11y.md` — the `a11y` lane: the `ux-a11y-scan.sh` groups, DEFECT / OK / NEEDS_VISUAL
  triage, and the fix each smell maps to.
- `references/report.md` — how to **write** the report: the `findings.json` schema, the section
  order (it is `kit-docs-writer`'s page template, filled for an audit), the voice, and the visual
  identity (Datatype display + Open Sans body + IBM Plex Mono for evidence, semantic + accessible HTML).

## 0. Orient, pick lane & target

1. Read `./.claude/kit.config.json` if present (for `apps`, repo root). Not required.
2. **Lane:** honor `--lane`. No flag: request about consistency / variants / hand-rolled UI →
   `consistency`; request about accessibility / semantic HTML / ARIA / keyboard → `a11y`;
   otherwise `flows`. If ambiguous, `AskUserQuestion` (flows / consistency / a11y / all).
3. **Target app:**
   - `--path <dir>` → that directory. Skip enumeration.
   - Else `bash "${CLAUDE_PLUGIN_ROOT}/scripts/ux-graph-scan.sh" --apps <root>` — lists every
     app-like package (has `react`/`next`/`vue` + a `dev` script) with framework + router.
     0 → stop ("No component front-end found under <root>."). 1 → use it, say which. 2+ →
     `AskUserQuestion` which to audit (honor `--app <name>`).
4. **Consistency-lane inputs:** resolve `--primitives` (the shared UI barrel, e.g.
   `packages/ui/src/index.ts`), `--css` (the app theme/token file, repeatable), `--css-prefix`
   (the project's custom-class prefix, if it has one — no default; the section-8 hunt is skipped
   without it). If the project ships a rules file naming these (`.claude/rules/*ui-convention*`),
   read it first. Missing barrel → run anyway, note the gap.
5. Record for the report: lane, target path, framework, router, monorepo yes/no.
6. `--dry-run` → print the resolved lane, target, graph source, and the checks that will run, then
   stop. Touch nothing.

## 1. Get the graph  (`flows` / `all`)

Target dir = `$T`. Prefer an existing rich graph; never rebuild silently.

1. `$T/graphify-out/graph.json` **or** `./graphify-out/graph.json` exists and **no**
   `--rebuild-graph` → use it. Report "graph source: graphify".
2. Else `bash "${CLAUDE_PLUGIN_ROOT}/scripts/ux-graph-scan.sh" --scan "$T"` → writes
   `$T/graphify-out/.ux_graph.json` (normalized model). Report "graph source: deterministic scan
   (approximate)".
3. Say **once**, without blocking: "For a richer semantic graph, run `/graphify $T` first, then
   re-run." Never wait, never prompt for an API key — the fallback is enough.
4. `--rebuild-graph` + graphify installed → you MAY run `/graphify "$T" --directed` first (best
   graph for this skill). Only on the explicit flag.

Normalize to `references/graph-model.md`, persist to `$T/graphify-out/.ux_model.json`, and derive:
click-depth per screen from each entry route, god-nodes, community bridges, the edit-surface map.
Keep it compact — you hand slices to the agent, not the whole graph.

## 2. Run the checks

### Lane `flows`

Spawn the **ux** agent (`templates/agents/ux.md`; in an onboarded project
`.claude/agents/ux/AGENT.md`). Give it **only** these slices as compact JSON — never source files:
routes/screens with click-depth · god-nodes (id, fan-in, rendering screens) · community bridges ·
per `data-entity` its `reads`/`writes`/`mutates` edges + source screen · per `form` its field
count, required count, multi-step?, host screen(s), any `duplicates` edge.

Ask it to apply **every** heuristic in `references/heuristics.md` and return findings in the
`findings.json` schema (`references/report.md`). Agent rule: **never invent an edge** — if a
verdict needs something the graph doesn't show, set `needs_visual: true` and say what to check.

For a large app, fan classification out to read-only `Explore` sub-agents (one per heuristic
group), each briefed with `references/heuristics.md`.

### Lane `consistency`

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/ux-ds-audit.sh" "$T/src" \
  [--exclude <re>] --primitives "<ui-barrel>" --css "<theme.css>" [--css-prefix <p>] \
  > "$T/graphify-out/.ux_ds_audit.txt"
```

Then follow `references/consistency.md`: classify every primitive-with-className row into
LAYOUT / VISUAL / BEHAVIOR, run the sibling-screen comparison for a page scope, map hand-rolled
recipes to the primitive that should own them, judge custom CSS (variant-in-disguise vs layout vs
dead). Emit the same `findings.json` schema (heuristic ids `C1`…`C6`). Fan out to `Explore`
sub-agents by section group for a large scope.

### Lane `a11y`

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/ux-a11y-scan.sh" "$T/src" [--exclude <re>] \
  > "$T/graphify-out/.ux_a11y_scan.txt"
```

Then follow `references/a11y.md`: triage every row DEFECT / OK / NEEDS_VISUAL, map each DEFECT to
its fix (the native element, the text alternative, the label wiring, the heading/landmark
structure, the focus/keyboard fix), and cite the project's own `.claude/rules/*` slug where one
applies. Emit the same `findings.json` schema (heuristic ids `A1`…`A5`). Fan out to `Explore`
sub-agents by group for a large scope. This is a source check — say in the report that a
rendered-app axe / Lighthouse run still belongs on the list.

## 3. Optional visual verification (`--visual` only)

Without `--visual`: skip. The report still lists every `needs_visual` finding under "Candidates for
visual review" (screen + what to look at), ranked by severity.

With `--visual`:
1. Find a base URL: a `dev`/`start` script + conventional port, or ask the user. No server → skip
   captures, keep the candidate list, say so in the report.
2. For each `needs_visual` finding of severity `crit`/`p1`, up to a cap (default 8): navigate with
   Playwright or the Chrome MCP, screenshot the screen, save under
   `$T/graphify-out/ux-audit/shots/`. **Never trigger a native browser dialog.**
3. Record each shot's filename on its finding (`"shot": "<id>.png"`) so it renders inline.

## 4. Write the report

There is **no renderer**. Load the **`kit-docs-writer`** skill and write
`$T/UX_FLOW_REPORT.html` from `findings.json`, following `references/report.md`:

- the section order there **is** `kit-docs-writer`'s page template, filled for an audit (title →
  one-line description → run facts → one diagram if it earns its place → findings grouped by
  severity → flow map → edit-surface table → still-to-check → what to do next);
- its voice rules apply — zero analogies, define each heuristic term once, front-load, lists over
  prose, callouts sparingly;
- the visual identity is fixed: **Datatype** (Google Fonts) as the protagonist display face for
  the title, headings, finding lead lines and severity counts; **Open Sans** for body;
  **IBM Plex Mono** for evidence/ids/paths; antialiased; one embedded `<style>`, screenshots as
  `data:` URIs;
- the HTML is a full, semantic, accessible, theme-aware document (landmarks, one `<h1>`, ordered
  headings, `<dl>`/`<table>`/`<ul>` for the right content, skip link, `:focus-visible`), readable
  with no JavaScript.

**Not an artifact.** It is a file in the target repo. Do not publish it with the Artifact tool.
Run the `kit-docs-writer` checklist and the accessibility list in `references/report.md` before
calling it done.

## 5. Open the report, then report back (TOON, terse)

**Open the report and hand the user a direct link to it — this is the last action, always.**

```bash
REPORT="$T/UX_FLOW_REPORT.html"
case "$(uname)" in
  Darwin) open "$REPORT" 2>/dev/null || true ;;
  Linux)  xdg-open "$REPORT" >/dev/null 2>&1 || true ;;
esac
printf 'Report: file://%s\n' "$(cd "$(dirname "$REPORT")" && pwd)/$(basename "$REPORT")"
```

Print that **bare `file://` URL as the final line of the reply** (no markdown link — terminals
don't render OSC 8). If `open`/`xdg-open` is unavailable or headless, still print the URL and say
the file is ready to open.

Then print the top findings by severity as a small TOON table (heuristic · entity/scope · screens ·
severity). Then offer one trace:

> "The most tangled flow this graph shows: **<entity>** is edited from <n> screens (<list>). Want me
> to trace how they diverge?"

Yes + graphify source → `/graphify path "<screenA>" "<entity>"`. Otherwise walk the `writes`/
`mutates` edges for that entity from the graph JSON and show where the forms differ.

Then `AskUserQuestion` for every open call (effort split, which of two competing treatments wins,
widths/paddings, anything with a visual value). Label assumed vs decided.

## 6. Route + hand off

- Findings are analysis, not tickets — this skill does not file GitHub issues. Whole app / many
  files → `/kit-effort-new` (in the consistency lane: a foundation sub first, sweeps parallel, a
  variant-adoption sweep last). One screen/component → the quick lane, still in a worktree.
- **Consistency lane:** design DECISIONS (a new visual value, which of two treatments wins, a new
  variant's look) → the **designer** agent. IMPLEMENTATION with existing tokens → the **frontend**
  agent. Every new shared primitive/variant lands with its inventory row in the project's UI
  conventions rule + its barrel export in the same PR.
- **Verification of a consistency pass** = re-run `ux-ds-audit.sh` on the same scope and
  re-classify: none may classify VISUAL; hand-rolled recipe sections are zero outside the UI
  package.

## Rules

- **Graph / script first, files last.** Never read component source screen-by-screen. Open a file
  only to confirm a specific flagged finding, capped at 12 files, and report the count.
- **Never rebuild graphify implicitly.** `--rebuild-graph` is the only regenerating path.
- **No API key, ever.** The fallback scan is deterministic.
- **`--visual` is the only image-token cost and it is opt-in.** Default runs are text-only.
- **The agent never invents an edge.** Ambiguous → `needs_visual: true`, not an assertion.
- **The report is written, not rendered, and never an artifact.** Author it from `findings.json`
  via `kit-docs-writer` per `references/report.md` — one self-contained HTML file in the target
  repo. Datatype is the protagonist face; Open Sans is the body; IBM Plex Mono is the evidence.
  The document itself must pass the same
  bar the `a11y` lane checks for: full doctype + `lang`, landmarks, one `<h1>`, ordered headings,
  `<dl>`/`<table>`/`<ul>` for the right content, a skip link, `:focus-visible`, readable with no
  JavaScript.
- **Lane boundary:** `flows` H8/H9 flag *structural* pattern divergence and shared-component
  overload only; the *visual/token* judgment (className diff, variant proposals) is the
  `consistency` lane; *semantic-element and accessibility* defects are the `a11y` lane. Don't
  double-report the same node in more than one lane — cross-link instead.
- **Project-agnostic.** This skill hardcodes no framework token names, no primitive library, no
  path conventions beyond the common ones it probes for. Everything project-specific arrives as a
  flag or is read from the project's own `.claude/` rules at run time.

## Optional: seed a graphify graph at install time

Seeding the graph once makes every later run richer and cheaper. Opt-in, outside the default flow:
1. `graphify detect` on the app → report corpus size + a token estimate.
2. Recommend by cost: `--directed` always (this skill wants edge direction); `--mode deep` only if
   the app carries many docs/specs; `--no-viz` if > 5000 nodes; `--neo4j-push` only if the project
   already runs Neo4j. Default otherwise.
3. Build only on explicit confirmation. Never as a side effect of onboarding.
