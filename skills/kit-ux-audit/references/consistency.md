# kit-ux-audit — consistency lane

Design-system consistency pass over a chosen scope (an app, a route group, a page, a component, a
directory). **Detection is `scripts/ux-ds-audit.sh`** (grep/perl, `$0`, macOS-safe) — **judgment
is the model** (classify, compare siblings, propose variants, route decisions). Never eyeball code
for a pattern the script already finds.

Nothing here is project-specific: the shared-UI barrel, the custom-class prefix and the theme file
are all parameters (`--primitives` / `--css-prefix` / `--css`). Read the project's own
`.claude/rules/*ui-convention*` (if any) at run time for the values and the rule-slugs findings
should cite.

## 1 · Pick the scope (ask, don't guess)

`AskUserQuestion` with these options unless the request already names one:

| Scope | `<path>` example | Extra |
| --- | --- | --- |
| whole app | `apps/web/src` | `--exclude '<regex>'` when a second surface lives in the app |
| route group / page | `apps/web/src/app/sign-in` | also pass its **sibling** screens for §3 |
| component | `src/components/course-card.tsx` | plus every file that renders it |
| package | `packages/ui/src/components` | flips the question: are the variants the apps need present? |

Always pass `--css <theme.css>` for the app's token/theme file, and `--css-prefix <p>` if the
project uses a prefix for its custom classes (without it, section 8's TSX custom-class hunt is
skipped).

## 2 · Detect (deterministic)

```bash
scripts/ux-ds-audit.sh <path> [--exclude <re>] --primitives <ui-barrel> --css <theme.css> [--css-prefix <p>] > /tmp/ux-ds.txt
```

Ten sections, each `(N hits)` + `file:line` rows:

1. **PRIMITIVE_CLASSNAME** — shared-UI primitives rendered with a `className` (the variant-candidate pool)
2. **HEADINGS** — `<h1-3>` carrying a display/`type-*` role outside a heading primitive
3. **CARD_SURFACES** — `rounded` + border + surface bg typed by hand on a non-Card element
4. **SKELETONS** — `animate-pulse` outside the UI package + fill-token drift
5. **STATUS_LINES** — `role=status|alert` / `aria-live` typed by hand
6. **RAW_CONTROLS** — raw `<button|input|select|textarea>` + underline-link recipes
7. **CARD_GRIDS** — `grid grid-cols-*` recipes (page ↔ `loading.tsx` drift shows here)
8. **CUSTOM_CSS** — `<prefix>-*` classes + `data-*` styling hooks in TSX; dead classes; rules that
   reach into a primitive's `data-slot`
9. **ICON_PROPS** — repeated `<XxxIcon size={N} strokeWidth={S}>` tuples
10. **REPEATED_CLASSNAMES** — identical multi-utility `className` literals appearing 3+ times

For a large scope, fan classification out to read-only `Explore` sub-agents (one per section
group), each briefed with this file.

## 3 · Judge (the model's half)

**Classify every §1 row** into exactly one bucket:

- **LAYOUT** — placement only (`mt-*`, `w-full`, `mx-auto`, `max-w-*`, `shrink-0`, `self-*`, grid/
  flex placement). Fine. No action.
- **VISUAL** — color, bg, border, radius, shadow, font/`type-*`, size (`h-*`, `p-*`, `px-*`),
  `rounded-*`, hover/active state, or a custom CSS class on the primitive. **Variant candidate.**
  Group by (component, override string); 2+ hits or a clear re-skin → propose
  `variant`/`size`/`shape`/`tone` on the primitive's variant map. Explicit variants, never
  booleans.
- **BEHAVIOR** — `hidden md:flex`, `print:hidden`, `sr-only`, `data-*` hooks. Legitimate call-site
  concern. Keep.

**Sibling-screen comparison** (page scope): diff the screens that should look the same (sign-in vs
register vs verify; list pages under one route group; page vs its `loading.tsx`). One row per
property, one column per screen: width, padding, header shape, back-link treatment, card nesting (a
Card inside a Card is a bug), icon variant, skeleton shape.

**Hand-rolled → foundation** (§2–§7, §9, §10): map each recipe to the primitive that should own it
(a heading/PageHeader, Card, Skeleton, StatusText, CardGrid, EmptyState, Button, TextLink …).
Missing primitive → check the component registry the project uses (e.g.
`npx shadcn@latest search <term>`), record "used <x>" or "no fit because …".

**Custom CSS** (§8): a theme rule restyling `[data-slot='…']` / `[role='…']` from outside is a
**variant in disguise** → propose the prop, delete the rule. One-off page decoration (covers,
parallax, art direction) stays. Zero-reference classes are dead → delete.

## 4 · Findings

Emit the `findings.json` schema (`report.md`) with heuristic ids `C1`…`C6`:

| id | finding |
| --- | --- |
| `C1` | Variant candidate — component · override string · hits · proposed prop |
| `C2` | Hand-rolled recipe → primitive that should own it (+ registry check) |
| `C3` | Sibling-screen drift — property · per-screen values · diagnosis |
| `C4` | Custom CSS verdict — variant-in-disguise / layout-keep / dead-delete |
| `C5` | Repeated className literal → component or variant, with locations |
| `C6` | Card-in-Card / structural nesting bug |

`severity`: `crit` never (consistency is not a blocker) · `p1` core component or ≥ 2 screens
diverge · `p2` localized · `p3` single-site polish. `needs_visual: true` when the verdict depends
on how it *looks* rendered (re-skin vs coincidence).

## 5 · Route

- Design DECISIONS (a new visual value, which of two treatments wins) → **designer** agent.
  IMPLEMENTATION with existing tokens → **frontend** agent.
- Whole app → `/kit-effort-new`: a foundation sub first, sweeps parallel, a variant-adoption sweep
  last. One component/page → the quick lane, still in a worktree.
- Every new shared primitive/variant lands with its inventory row in the project's UI-conventions
  rule + its barrel export, same PR.
- **Verification** = re-run `ux-ds-audit.sh` on the same scope and re-classify the refreshed §1
  rows: none may classify VISUAL; §4/§7 are zero outside the UI package; §8 shows no rule reaching
  into a `data-slot`.
