# Kito theme study

2026-11-19. Requested by José after distinguishing visual theme from content rewriting.
Source: `docs-site/src/pages/design/theme.astro`. Preview route: `/design/theme/`.
The current docs theme is unchanged. This is an isolated design study, not an approved site-wide theme.

## Direction

Warm editorial desktop: ivory paper, forest ink, cobalt actions, measured offset shadows,
small registration marks and halftone dots. Geist for reading and controls; Geist Mono for
annotations and commands. Reuses the approved trio from the reference directory.
José named the characters: Nota (Post-it), Kito (terminal), Memo (USB). Their names appear
below each character, at a deliberately small size. The header uses the approved illustrated
cckit logo from the reference sheet through StickerLogo.astro. The temporary CSS wordmark
sticker above the trio was removed after José clarified its placement.
The logo component displays the original raster artwork inside an SVG viewport; it is not a vector redraw.

The page shows the same composition in light and dark, with Compare / Light / Dark controls.
It includes primary/secondary/disabled/loading buttons, a text link, keyboard-operable tabs,
a copyable command, guide card, Post-it annotation, a local-only form with error/success states,
status labels, five brand swatches and typography. A 1-second delay demonstrates loading only.
The form makes no request and stores no data. Site links lead to existing docs.

## Semantic color proposals

| Role | Light | Dark |
| --- | --- | --- |
| Page | `#F2F4EB` | `#1B211D` |
| Surface | `#FBFCF7` | `#252E27` |
| Text | `#202521` | `#F2F4EB` |
| Secondary text | `#596252` | `#B1BCAA` |
| Action | `#2457D6` | `#91B1FF` |
| Action text | `#FFFFFF` | `#142348` |
| Control border | `#89917F` | `#7B8B75` |
| Focus | `#2457D6` | `#ACC4FF` |
| Success text | `#526A3D` | `#B4CEA0` |
| Warning text | `#806117` | `#E6C777` |
| Error text | `#A52D31` | `#FFA9A6` |

Brand swatches retain the original colors; semantic variants serve text and controls.
Calculated WCAG luminance ratios: main text 14.03/14.76, secondary text 5.74/8.30,
action text 6.16/7.29, control border against surface 3.17/3.86 (light/dark).
Success text on its tinted surface 4.94/6.64; warning text 4.75/7.11;
error text against page 6.26/8.95. These are calculations from declared colors, not browser
measurements or certification of every state/pixel.

## Validation and remaining review

The new route rendered during `pnpm --dir docs-site build`, but the full build failed later
at existing `/og/adapters.png`: `ENOTFOUND api.fontsource.org` fetching its Noto Sans font.
The study compiled separately with the existing Astro dependencies, no new packages,
and the noop image service to retain the original reference image without requiring Sharp.
That isolated build passed with one page. The generated browser JavaScript passes `node --check`.

CSS includes responsive layouts, visible focus and reduced-motion overrides. Tabs implement
ArrowLeft/ArrowRight/Home/End; forms associate errors and labels. These behaviors are implemented
but were not verified interactively: Chrome DevTools could not acquire its occupied profile;
the in-app browser failed with a tab/session mismatch. Desktop/mobile visual review, clipboard
permissions and screen-reader behavior remain to be checked in the user's browser.

No push, merge or deployment. Prose review: O13 addressed by distinguishing calculated contrast,
implemented interaction and completed checks. O14: theme remains exploratory pending visual review.

## Follow-up: names and sticker

Added the cckit.dev wordmark sticker and the names Nota, Kito and Memo below the trio.
The live in-app browser was available for this revision. The new names and sticker were
verified in the DOM and visually in the two-theme desktop view. A character-image overlap
with the text was corrected by keeping the figure within its column. This does not establish
mobile or screen-reader verification.

## Animated footer

KitoFooter.astro adds a reusable banner in both themes with the original ornament sheet,
a pointing Kito, a floating note, subtle CSS motion, a pause control and real guide/reference/
GitHub links. Its isolated Astro build passes. Desktop composition and the light-theme pause
control were reviewed in the live browser. Mobile, reduced-motion emulation and screen readers
remain pending. Continue with footer-claude-prompt.es.md.
