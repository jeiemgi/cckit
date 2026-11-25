# Minimum rules, for when a design skill is not installed

cckit's own rules. They are a floor: they keep a page from the worst defaults when one of the
three design skills is missing. They are not that skill, and the design file must still say which
skill was `not installed`. Apply only the section for the missing skill.

## Direction — when `impeccable` is not installed

1. Build the page around the brief's one visual idea: the first screen shows it without scrolling.
2. Sections follow what the audience came to do, in that order. Leave out a section the brief
   gives no content for.
3. At most two type families. Headings differ from body text in weight or family, not size alone.
4. Body text: 16px or more, lines of 45 to 75 characters, left-aligned.
5. One colour carries meaning (the action); the rest of the palette is neutral. Use the values in
   the brief, not the framework's defaults.
6. Spacing comes from one scale. Sections do not all get the same height and padding.
7. No pattern from the brief's "Refuses to look like" list.
8. No invented content: no customer name, quote, logo or number the task did not supply.

## Motion — when `emil-design-eng` is not installed

1. An animation needs a reason a person could state: it shows where something came from, or
   that an action registered. No reason, no animation.
2. No fade-in on scroll for whole sections.
3. Animate `transform` and `opacity` only.
4. Interface transitions last 150 to 300ms. Something that enters eases out; nothing a person
   triggers often is delayed.
5. Hover and pressed states exist only on things that can be clicked.
6. Under `prefers-reduced-motion: reduce`, movement is removed, not shortened.

## Audit — when `web-design-guidelines` is not installed, or its rules cannot be fetched

Report this as "cckit's minimum checks", never as the audit. Check each in the code:

1. Body text contrast is at least 4.5:1 against its background; large text at least 3:1.
2. Everything clickable is a link or a button, reachable with the keyboard, with a visible focus
   style.
3. Every image has `alt` text, empty for a decorative one. Every form field has a label.
4. One `h1`; heading levels are not skipped.
5. The page works at a width of 360px with no horizontal scroll; tap targets are 44px or more.
6. `prefers-reduced-motion` is honoured.
7. The page has a `lang` attribute and a title.
