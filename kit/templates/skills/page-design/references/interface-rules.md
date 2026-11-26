# Interface rules — grid, radii, tables, error surfaces

cckit's own rules for any interface, with the check for each. `page-design` applies them in its
direction step; `kit-ux-audit`'s consistency lane reports a value that breaks one (`C7`, `C8`).
Values are generic: a project's tokens name them, this file does not. A project rule that sets a
different grid or table pattern wins; say so in the design file.

## 1 · Grid

| Rule | Check |
| --- | --- |
| Box sizes — padding, gap, margin, radius, width, height, icon size — are multiples of 4px | no px value outside the 4px grid in CSS, tokens, utility classes, inline styles or SVG |
| Font size and line height are even px | no odd font-size or line-height; line height is a rem pair with the size, never a unitless ratio |
| Tokens are rem that land on the grid at a 16px root | each rem token × 16 is a multiple of 4 (sizes) or an even number (type) |
| No odd or fractional value in any source | `grep -nE '[0-9]+\.[0-9]+(px|rem)'` and odd px values return only the listed exceptions |
| UI text is 12px or larger | no font-size below 0.75rem / 12px outside a listed exception |
| Exceptions are listed with their reason | the design file names each one; standing exceptions: user-enlarged text, a 1px hairline |

## 2 · Radii

| Rule | Check |
| --- | --- |
| Tokens only, on the grid | no raw radius value in a component; each radius token is a multiple of 4px |
| Nested corner = outer − gap, floor 4px | a child inside a padded parent uses the parent's radius minus the padding, never the same token |
| Size sets the radius by the short side | the smaller control gets the smaller radius token; a radius never exceeds half the short side |
| Siblings match | elements in one row or list carry one radius token |
| Media is clipped | an image or video inside a rounded frame has the frame's radius and `overflow: hidden` |
| Borders inside, rings outside | a border is drawn on the element; a focus ring sits outside it and follows the same corner |
| Tables, code blocks and data grids get 0 or the smallest radius | no table, `pre` or grid frame above the smallest token |
| Pills nest pills | a rounded-full container holds rounded-full children only |

## 3 · Tables

| Rule | Check |
| --- | --- |
| The frame fills the view height; the head is sticky; the body scrolls inside; the pager is always visible | at any viewport height the head and the pager stay on screen while rows scroll |
| A single page disables both arrows and the card shrinks to its rows | with rows ≤ page size, both pager arrows are disabled and no empty space follows the last row |
| No matches: a state that offers to clear the filters | the empty-after-filter state names the filters and has one action to clear them |
| Read error: reference, retry, contact | the error state shows a reference id, a retry action and where to get help; rows are not faked |
| Pending: rows dim, progress under the head, pager stays | while loading, existing rows dim, a progress line sits under the head, head and pager keep their place |
| Row actions are icons with a label tooltip | every row action icon has a visible label on hover and focus, and an accessible name |
| A disabled action says why | a disabled row action's tooltip states the reason |
| A destructive action turns danger and confirms | delete and its kin use the danger tone and ask before acting |
| Bulk actions show a selection bar; select all matches; partial-success count; retry failed | selecting rows shows a bar with the count, an all-matches option, and after a run the done/failed counts with a retry for the failed |

## 4 · Error surfaces

One job each. A message in the wrong surface is a finding.

| Surface | Job | Check |
| --- | --- | --- |
| Banner | a state that holds: offline, read-only, expiring session | stays until the state ends; never reports an action |
| Toast | the outcome of an action the person just took | appears once, goes away, never carries the only copy of an error |
| Inline alert | a field or a section that cannot proceed | sits next to what it is about; names the fix |
| Read error | data that did not load | replaces the data region (see § 3); offers retry |

## Reporting a finding

Name the value, the rule it breaks (`§ 1` to `§ 4`), the file and line, and the nearest value on
the grid or the token that fits. A value covered by a listed exception is not a finding.
