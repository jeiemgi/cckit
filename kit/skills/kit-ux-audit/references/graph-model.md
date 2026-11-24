# kit-ux-audit — normalized graph model

Both graph sources (graphify `graph.json`, and the fallback `ux-graph-scan.sh`) are read into one
model before the heuristics run. Keep it as compact JSON; you hand **slices** to the agent, never
the whole graph and never source files.

## Nodes

```
{ "id": "screen:OrderDetail",
  "kind": "screen",              // route | screen | container | component | data-entity | form | field | mutation | store
  "label": "Order detail",
  "file": "app/orders/[id]/page.tsx",   // best-effort; may be absent from a semantic graph
  "meta": { "entry": false, "frequent": false, "steps": 1 } }
```

- `route` — a URL a user can land on. `meta.entry: true` for app entry points (`/`, `/dashboard`,
  post-login landing, anything with no inbound app nav).
- `screen` — the view a route renders. A route and its screen are often 1:1; keep both when the
  same screen backs several routes (H5).
- `container` — layout/nav wrapper that renders screens (root layout, route-group layout, tab
  shell). Carries the back/nav affordance for H4/H12.
- `component` — reusable UI unit. Fan-in matters (H9).
- `data-entity` — a domain object the UI reads or writes (`Order`, `Customer`, `Plan`). From a
  semantic graph, these exist directly; from the scan, they're inferred from query/mutation
  identifiers and table names.
- `form` — a form instance on a screen. `meta`: `fields`, `required`, `steps`, `hasDraft`,
  `hasStepper`.
- `field` — optional; only model individually when a cross-field rule (H6) or a create/edit diff
  (H7) needs it.
- `mutation` — a write operation (`createOrder`, `deleteCustomer`, server action, `useMutation`).
  `meta.verb`: `create|update|delete|archive|other`; `meta.guarded`: has a confirm step.
- `store` — shared client state (context/zustand/redux slice) when it's an editing surface.

## Edges

```
{ "from": "screen:Orders", "to": "data-entity:Order", "type": "writes",
  "meta": { "via": "form:OrderQuickEdit" } }
```

| type | meaning | main heuristics |
| --- | --- | --- |
| `imports` | module A imports module B | graph plumbing |
| `renders` | screen/container renders component/screen/form | H4, H5, H9, H10 |
| `navigates-to` | code path that changes route (`<Link>`, `router.push`, `redirect`, `navigate`, `<a href>` internal) | H3, H4, H5, H12 |
| `reads` | screen/component reads an entity (query, loader, `useX`, `select`) | H2, H10 |
| `writes` | screen/form persists an entity (non-destructive) | H1, H2, H10 |
| `mutates` | destructive write (delete/archive) | H1, H11 |
| `validates` | form ↔ field / field ↔ field validation rule | H6, H7 |
| `duplicates` | two forms / two routes judged equivalent (same entity + overlapping fields, or same screen under two parents) | H5, H7 |

`duplicates` from the scan is heuristic (name + entity + field-overlap ≥ 0.6). From graphify, use
`INFERRED` edges plus community co-membership.

## Derived metrics (compute before slicing)

- **click-depth**: BFS over `navigates-to` from every `meta.entry` route to each screen; store the
  minimum. Screens unreachable by `navigates-to` → depth `∞` → orphan candidates (H4).
- **god-nodes**: `component` (and `screen`) nodes ranked by inbound `renders` count. Top decile or
  fan-in ≥ 10 → H9 pool.
- **community bridges**: if the graph carries communities (graphify does; for the scan, run a quick
  label-propagation on the `renders`+`navigates-to` subgraph), collect edges whose endpoints are in
  different communities. These cross-feature edges are where "confusing" flows concentrate — feed
  them to the agent verbatim.
- **edit-surface map**: per `data-entity`, the set of `screen`s with a `writes`/`mutates` edge
  (directly or `via` a form). This is the H1 input and a report section on its own.

## Mapping graphify `graph.json` → this model

graphify nodes carry `type`/`kind` and `source_location`; edges carry a `relation` and an
`EXTRACTED|INFERRED|AMBIGUOUS` provenance.

- node `kind`: map `file`/`module` whose path matches a route convention (`app/**/page.*`,
  `pages/**`, `src/pages/**`, `src/routes/**`, a `*.route.*`) → `route`+`screen`; `layout.*` /
  `*Layout` → `container`; a component export rendered by screens → `component`; a symbol matching
  `/^use[A-Z]/` returning data or a Prisma/SQL/`.from(` call → fold into a `data-entity` +
  `reads`/`writes`; a `*Form`/`useForm` symbol → `form`.
- edges: graphify `imports`/`calls`/`renders` → `imports`/`renders`; a call into a router API →
  `navigates-to`; a call into a data client → `reads`/`writes`/`mutates` by verb.
- keep graphify `community` / `community_name` on nodes — reuse directly for bridges.
- provenance: treat `AMBIGUOUS` edges as `needs_visual` fuel, never as hard evidence.

Do the mapping in memory (or a tiny throwaway script). Persist the normalized graph to
`<target>/graphify-out/.ux_model.json` so a re-run can reuse it.

## Mapping the fallback scan → this model

`ux-graph-scan.sh --scan <dir>` already emits this shape at
`<dir>/graphify-out/.ux_graph.json` (`{ "nodes": [...], "edges": [...], "meta": {...} }`). It is
**approximate** — regex over TSX/Vue, not an AST. Mark the report "graph source: deterministic
scan" so findings are read with that caveat, and lean harder on `needs_visual`.
