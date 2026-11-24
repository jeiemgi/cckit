# Design Routing

## Hard rule

**ALL design and adjustment questions must be routed to the Designer agent.**

Includes (not limited to):

- Visual decisions: color, typography, spacing, layout, hierarchy
- Component design: primitives, variants, states (hover/active/disabled/loading/error/empty)
- Motion, animation, easing, durations
- Iconography, illustration, imagery
- Brand: logo, palette, tone, identity
- Information architecture, flow, navigation
- Microcopy and UX writing decisions
- Accessibility decisions that affect UI (contrast, focus states, tap targets)
- Responsive behavior and breakpoints
- "Adjustments" — any tweak to an existing screen or component, however small

## How to route

1. Do **not** answer from the orchestrator level
2. Spawn the Designer agent (`.claude/agents/designer/AGENT.md`)
3. Pass the question verbatim plus relevant context (screen name, token name, current state)
4. Return the Designer's answer to {{OWNER_NAME}}

## Why

Design decisions made by one agent stay consistent with each other. An ad-hoc visual call made
elsewhere can contradict the direction the Designer already set.

## Exception

Purely informational questions (e.g. "where is the design system saved?") can be answered directly.
The rule applies to _decisions_ and _adjustments_, not file lookups.
