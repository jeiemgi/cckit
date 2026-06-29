# Smart skill-gap detection ({{PROJECT_NAME}})

Surface a missing capability **before** starting work — but only when it's genuinely non-obvious, and
without nagging. Prompt for the **special and new**; stay silent on the **routine**.

## When to prompt (all must hold)

1. The task plausibly needs a **specific skill** — a framework/tool workflow, a design system, a data
   or automation capability — that is **not available** in this session and **not wired** to the agent
   that would do the work.
2. The need is **non-straightforward**: a special or new feature, not routine work you can already do
   well with general ability plus the skills already wired.
3. You have **not already asked** about this gap in this project (see anti-repeat).

If a capable skill is already available/wired → just use it, don't ask. If the work is routine → don't
ask. When unsure whether a gap is "obvious," lean toward **not** interrupting.

## How to prompt (once, up front, before starting)

State the gap in one line, then offer options via `AskUserQuestion`:

- **Pick a skill** — list the relevant skills actually available (the session's skill list,
  `~/.claude/skills/*`, installed plugin skills; discover with the `find-skills` skill) for the user to
  wire or use.
- **Provide one** — the user points to or supplies a skill / doc / MCP server.
- **Proceed without** — continue with general ability.

Route any wiring through **`/kit-customize`** (it attaches skills/tools to agents). Batch multiple gaps
for one task into a **single** prompt at the start — never drip-feed interruptions mid-task.

## Anti-repeat (don't nag)

Record outcomes in `.claude/kit.config.json` under `skillPrompts`:

```json
"skillPrompts": { "asked": ["<gap-key>"], "declined": ["<gap-key>"], "wired": ["<skill-name>"] }
```

- Before prompting, check `skillPrompts`. If the gap is already in `asked`, `declined`, or covered by
  `wired`, **do not ask again** — proceed silently.
- A `gap-key` is a short, stable slug for the capability (e.g. `gsap-animation`, `stripe-billing`,
  `playwright-e2e`).
- Ask **at most once per gap per project**. A declined gap stays declined unless the user reopens it.

## Principle

One good question up front beats five mid-task interruptions. Detecting a real, non-obvious capability
gap early — and remembering the answer — is the whole point.
