# React UI Annotation — Agentation loop ({{PROJECT_NAME}})

> Active because this project ran `/kit-annotate`. It wires the **Agentation** toolbar — an in-app,
> dev-only React component — to Claude via the `agentation` MCP server. Agentation is third-party
> (PolyForm Shield 1.0.0, source-available), installed as this project's own dev dependency; the kit
> vendors none of its code. To remove: delete this file, run `claude mcp remove agentation`, and drop
> the `<Agentation />` line from the app entry.

## What it gives you

Click any element in the **running dev app** (toolbar, bottom-right), leave a note with intent +
severity, and Claude pulls a structured record — CSS selector, position, nearby text, the **React
component tree**, and a **source file path** — then jumps to the code and fixes it.

## Honest limits — state these, don't over-promise

- **Dev-only.** The `<Agentation />` toolbar is gated behind a dev check and stripped from production
  builds. Only annotate against the dev server.
- **Identity is selector + source-path + component name, NOT live prop/state values.** Agentation does
  not serialize prop/state values. To pin the exact code, use the selector / source path / component
  name to **grep** the repo.
- **React Server Components** render only on the server → a clicked server-rendered node degrades to a
  CSS selector. Client components annotate fully.
- The MCP payload Claude receives is lighter than the toolbar's **Copy** markdown. If a needed detail
  is missing, ask the user to hit **Copy** in the toolbar and paste it.

## The session loop

**Default to a batch contract.** Open with: *"Annotate everything you want changed, then say 'done' —
I'll pull the whole batch and apply the fixes."* Let the user mark up the whole screen and hand off a
reviewed batch; don't lead with a silent live watch that picks notes up mid-thought.

When the user says "done" / "go" / "I left notes" (or runs `/kit-annotate`):

1. **Pull** the batch — `agentation_get_all_pending`. (Only use `agentation_watch_annotations`, which
   blocks silently until new notes arrive, if the user **explicitly opts into** hands-free / "watch".)
2. For **each** annotation:
   - `agentation_acknowledge` — mark it seen (flips the note's state in the toolbar).
   - **Locate the code:** use the source file path if present; otherwise grep the selector / class
     names / component name / nearby text.
   - Make the fix, following this project's build skills and conventions.
   - `agentation_resolve` with a one-line summary of the change — or `agentation_dismiss` with a reason
     if it isn't actionable, or `agentation_reply` to ask a clarifying question.
3. In hands-free mode only, call `agentation_watch_annotations` again and continue until the user stops.

**Set expectations** so the browser side isn't a black box: notes flip **acknowledged → resolved** in
the toolbar as you work; fixes land via **HMR** — *refresh to see them*; each resolved note carries a
one-line summary.

**Preflight:** the MCP server runs the toolbar's HTTP receiver on **:4747**; it starts with Claude Code
once registered. If the `agentation_*` tools are missing, restart Claude Code and verify with
`npx agentation-mcp doctor`. If `agentation_list_sessions` shows **connected but 0 sessions** while the
user is annotating, the wired `<Agentation endpoint="http://localhost:4747" />` is **missing its
`endpoint` prop** (toolbar is writing only to `localStorage`) or the tab is stale — fix the wiring /
reload before continuing.

<!-- IF:MEMORY -->
## On session close

Before the closing summary, write a short record to MemPalace wing **`{{WING}}`** (room `problems` or
`decisions`): which annotations were resolved, the components/files touched, and anything deferred.
Keeps UI-fix history per project.
<!-- /IF:MEMORY -->

## Scope

Wired for **Claude Code**. Other agents (Cursor, Codex, …) can read the same annotations through
Agentation's own MCP/export — that is Agentation's surface, not the kit's; the kit neither wires nor
maintains it.
