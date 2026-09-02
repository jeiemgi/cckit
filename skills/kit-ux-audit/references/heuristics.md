# kit-ux-audit — heuristic catalogue

The audit itself. The **ux** agent applies every heuristic below to the graph slices it receives
(§2 of SKILL.md). Each has: the graph signal that triggers it, the default severity, and whether a
finding needs visual confirmation (`needs_visual`) rather than being assertable from structure alone.

Severity: `crit` (blocks a core task / data-loss risk) · `p1` (frequent friction) ·
`p2` (noticeable, localized) · `p3` (polish).

Node kinds referenced: `route` `screen` `container` `component` `data-entity` `form` `field`
`mutation` `store`. Edge types: `imports` `renders` `navigates-to` `reads` `writes` `mutates`
`validates` `duplicates`. See `graph-model.md` for how both graph sources map to these.

---

## H1 — Scattered edit surfaces (multiple sources of truth)

**Signal:** one `data-entity` has `writes` or `mutates` edges from ≥ 3 distinct `screen` nodes.
**Why it hurts:** the user (and the team) can't predict where a value "really" changes; edits made
in one place look absent in another.
**Severity:** `p1` (≥ 3 screens) → `crit` if the screens disagree on which fields they expose.
**Report:** list every editing screen for the entity, and whether each is full CRUD or partial.
**needs_visual:** false (structural).

## H2 — Read/write asymmetry

**Signal:** a `screen` has a prominent `reads` edge to an entity (rendered in a detail view / table)
but no `writes`/`mutates` edge to it and no `navigates-to` edge to a screen that has one — or the
inverse (write-only screen with no confirmation/readback).
**Why it hurts:** "I can see it but I can't change it here, and nothing tells me where to."
**Severity:** `p2` → `p1` if the entity is core (high fan-in).
**needs_visual:** true — confirm the field is actually surfaced as if editable.

## H3 — Deep path to a frequent action

**Signal:** click-depth from an entry `route` to a `mutation` (or the `screen` that hosts it) ≥ 4,
where the mutation is flagged frequent (create/save on a core entity, or high fan-in).
**Why it hurts:** routine work costs too many navigations.
**Severity:** `p1` (depth 4) → `crit` (depth ≥ 6 or no shortcut/deep-link exists).
**Report:** the shortest path found, and whether a deep link or command exists to skip it.
**needs_visual:** false.

## H4 — Orphan / dead-end screen

**Signal (orphan):** a `route`/`screen` with zero inbound `navigates-to` edges from within the app
(reachable only by typing the URL). **Signal (dead-end):** a `screen` with zero outbound
`navigates-to` and no back affordance in its container.
**Why it hurts:** orphans are undiscoverable; dead-ends trap the user.
**Severity:** `p1` → `p2` if it is an intentional deep-link target (e.g. an email link landing).
**needs_visual:** true for dead-ends (a global nav / breadcrumb may provide the exit).

## H5 — Ambiguous / divergent duplicate route

**Signal:** two `route` nodes resolve to the same `screen`/`data-entity` view but sit under
different `container` parents (different layout, nav context, or breadcrumb), or the same screen is
`renders`-reachable from ≥ 2 containers with different chrome.
**Why it hurts:** the user can't tell "where they are"; bookmarks and links behave inconsistently.
**Severity:** `p2` → `p1` if the two versions expose different actions on the same entity.
**needs_visual:** true — confirm the chrome/actions actually differ.

## H6 — Heavy form

**Signal:** a `form` node with any of: field count ≥ 12; required-field ratio ≥ 0.7 with count ≥ 8;
≥ 2 cross-field `validates` dependencies; multi-step (`form` spans ≥ 2 `screen`/step nodes) **with
no** progress/stepper node; no autosave/draft `mutation` on a form that is long or multi-step.
**Why it hurts:** high completion cost, high abandonment, lost work.
**Severity:** `p1` → `crit` for multi-step + no progress + no draft on a core flow.
**Report:** the specific triggers (count, required ratio, steps, missing stepper/draft).
**needs_visual:** true for "no progress indicator" (a stepper may be rendered but not modeled).

## H7 — Diverging create vs edit form

**Signal:** a `duplicates` edge between two `form` nodes (or two forms writing the same entity)
whose field sets differ by more than labels — one exposes fields the other hides, or validation
differs.
**Why it hurts:** you can create a record you can't fully edit later, or vice versa; rules feel
arbitrary.
**Severity:** `p1`.
**Report:** field-level diff (present-in-create / present-in-edit / different-validation).
**needs_visual:** false (structural), unless field identity is uncertain → then true.

## H8 — Inconsistent pattern for the same job

**Signal:** the same task (same `mutation` verb on the same entity kind, or `renders` of the same
primitive role) is presented three different structural ways across screens — e.g. one entity is
edited inline in a table on screen A, in a modal on screen B, on a dedicated route on screen C.
**Why it hurts:** every screen re-teaches the interaction.
**Severity:** `p2` → `p1` if it's a core entity.
**needs_visual:** true — confirm the presentation modes (modal vs page vs inline) from the screen.
**Scope note:** presentation/token drift on shared primitives (className overrides, "variants in
disguise") is a **design-system** concern — that is the `consistency` lane, not this one. H8 is
only about *structural* pattern divergence for the same task.

## H9 — Configuration-overloaded shared component ("god component")

**Signal:** a `component` node with fan-in ≥ 10 (`rendered` by many screens) AND a wide prop/variant
surface (many distinct call-site configurations in the graph, or flagged by the scan as a repeated
high-arity call).
**Why it hurts:** one component tries to be every screen's answer; call sites are hard to reason
about and easy to misconfigure.
**Severity:** `p2` → `p1` if its screens visibly diverge because of config.
**needs_visual:** false for the structural flag; true if recommending a split.
**Scope note:** the *deep* variant analysis belongs to the `consistency` lane; here just flag the
overload and its blast radius.

## H10 — Overloaded container / screen

**Signal:** a `screen`/`container` node with `reads`/`writes` edges to ≥ 4 distinct `data-entity`
nodes AND ≥ 2 child `form` nodes.
**Why it hurts:** the screen has no single job; users can't form a mental model of "what this page
is for".
**Severity:** `p2` → `p1` if it also hosts a core `mutation`.
**needs_visual:** true — confirm it reads as one dense screen, not well-separated tabs/sections.

## H11 — Inconsistent destructive-action guard

**Signal:** across `mutation` nodes whose verb is delete/remove/archive on comparable entities,
some have an associated confirm step/node and some do not.
**Why it hurts:** the user learns "delete asks first" on one screen and loses data on another.
**Severity:** `p1` → `crit` if any unguarded delete is irreversible on a core entity.
**Report:** guarded vs unguarded list.
**needs_visual:** true — a confirm dialog may be triggered in code the graph doesn't model.

## H12 — Navigation-away data-loss risk

**Signal:** a `screen` hosting a `form` with local edit state has outbound `navigates-to` edges (or
renders nav) with no unsaved-changes guard `node`/handler and no autosave `mutation`.
**Why it hurts:** a stray click discards typed work.
**Severity:** `p1` → `crit` for long/multi-step forms (compounds with H6).
**needs_visual:** true — a `beforeunload` / route guard may exist outside the graph.

---

## Output contract

For every triggered heuristic emit one finding object (schema in `report.md`):

```
{ "id": "H3-checkout-save",
  "heuristic": "H3", "title": "4 clicks from Home to save an order line",
  "severity": "p1",
  "entity": "OrderLine",
  "screens": ["Home", "Orders", "OrderDetail", "OrderLineEdit"],
  "evidence": ["path route:/ → screen:Orders → screen:OrderDetail → form:OrderLineForm",
               "no deep-link node to OrderLineEdit"],
  "confidence": "high",
  "needs_visual": false,
  "recommendation": "Add an inline edit on the Orders table row, or a /orders/:id/line/:n deep link." }
```

Rules for the agent:
- Run **all twelve**. A heuristic with no hits produces no finding — do not pad.
- **Never invent an edge.** If a verdict depends on something the graph doesn't contain, set
  `needs_visual: true` and say what to check, rather than asserting.
- Rank findings `crit` → `p3`, then by number of screens touched.
- Keep `recommendation` to one or two concrete sentences (a change, not an essay).
- Cite node/edge ids in `evidence` so the reader can find it in `graph.html` / the scan JSON.
