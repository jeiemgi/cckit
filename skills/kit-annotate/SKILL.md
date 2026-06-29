---
name: kit-annotate
description: Set up and run in-app visual UI annotation for a React project, wired to Claude via Agentation. Use AUTOMATICALLY when the user asks to set up / install visual annotation or an annotation toolbar, "annotate the UI / a component", click-to-annotate, give the agent visual UI feedback, review or triage UI annotations, or run "watch mode" for UI feedback. Targets a React app (Next.js, Vite, or React Router); installs the third-party `agentation` dev dependency + its MCP. Other agents are out of scope — this wires Claude Code only.
argument-hint: "[setup | watch | review | status] [--dry-run]"
allowed-tools: Bash, Read, Edit, Glob, Grep, AskUserQuestion, mcp__agentation__agentation_get_all_pending, mcp__agentation__agentation_watch_annotations, mcp__agentation__agentation_acknowledge, mcp__agentation__agentation_resolve, mcp__agentation__agentation_dismiss, mcp__agentation__agentation_reply, mcp__agentation__agentation_list_sessions, mcp__agentation__agentation_get_session, mcp__agentation__agentation_get_pending
---

# kit-annotate — visual UI annotation for React, wired to Claude

This sets up and drives **click-to-annotate** UI feedback for a React app. You point at a component in
your running dev app and leave a note; Claude reads a structured record and fixes the code. It **adopts
Agentation** — a maintained, source-available (PolyForm Shield 1.0.0) npm package — as the capture
engine, and wires it into Claude: install, MCP registration, a project rule, and the fix loop. The kit
vendors none of Agentation's code; it installs it as the project's own dev dependency.

**Scope is Claude Code only.** Agentation is agent-agnostic on its own (Cursor/Codex via its MCP/export),
but the kit wires and maintains the Claude path only — say so if asked about other agents.

The kit lives at `${CLAUDE_PLUGIN_ROOT}`; the setup engine is
`${CLAUDE_PLUGIN_ROOT}/scripts/annotate-setup.sh` (which sources `scripts/lib/react-detect.sh`).

## 0. Orient

- Read `./.claude/kit.config.json` if present. If `.annotate.enabled == true`, this project is already
  set up → default to **watch/review**. Otherwise default to **setup**. Honor an explicit
  `$ARGUMENTS` mode (`setup` · `watch` · `review` · `status`) over the inference.
- No `.claude/` at all? Setup still works, but mention that running `/kit-init` first gives the full
  integration (the rule lands in `.claude/rules/`, and memory enables the on-close summary).

## 1. Setup mode

1. **Detect + preview.** Run the engine in dry-run from the project root and show the plan:
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/annotate-setup.sh" --dry-run
   ```
   If it reports **No React app detected**, stop — this targets React apps. If the framework is
   `react` (unrecognized: CRA/Gatsby/etc.), tell the user you'll install + register but they must wire
   the `<Agentation />` line manually.
2. **Explain what becomes doable, then ask consent.** In plain terms: *click a component in your dev
   app → leave a note → Claude reads the component + selector + source path + your comment and fixes
   it; optionally hands-free, where Claude watches for new notes and resolves them as you go.* State the
   **honest limits** up front — dev-only (stripped from production); identity is selector + source-path
   + component name, **not** live prop/state values, so Claude greps to the file; React Server
   Components degrade to a selector. Note the **license**: Agentation is PolyForm Shield, free for this
   use, installed as the user's own dev dependency. Then `AskUserQuestion`:
   **Install** · **Preview only (dry-run)** · **Skip**.
3. **Install.** On consent, run the engine for real (no `--dry-run`). It installs the dep, registers the
   `agentation` MCP for Claude, writes `.claude/rules/react-annotate.md`, and records `.annotate` in
   `kit.config.json`.
4. **Wire the dev-only toolbar into the app entry — via `Edit`, showing the change first.** The engine
   prints the exact snippet + the detected entry file. **The `endpoint` prop is mandatory** — without it
   the toolbar boots `disconnected`, writes only to `localStorage`, and annotations never reach the MCP
   receiver (Claude sees 0 sessions). Use the port from `kit.config.json → annotate.mcp.httpPort`
   (default `4747`). Apply it per framework:

   | Framework | Entry file | How to wire |
   | --------- | ---------- | ----------- |
   | **Next.js (App Router)** | `app/layout.tsx` | Add `import { Agentation } from "agentation"` and, inside `<body>` after `{children}`, `{process.env.NODE_ENV === "development" && <Agentation endpoint="http://localhost:4747" />}`. The component is a client component; if `layout.tsx` is a Server Component, render it from a tiny `'use client'` wrapper, or place it in a client root. |
   | **Next.js (Pages Router)** | `pages/_app.tsx` | Same import; render `{process.env.NODE_ENV === "development" && <Agentation endpoint="http://localhost:4747" />}` after `<Component {...pageProps} />`. |
   | **Vite** | `src/main.tsx` | Import it; render `{import.meta.env.DEV && <Agentation endpoint="http://localhost:4747" />}` next to `<App />` inside the root render. |
   | **React Router v7 (framework mode)** | `app/root.tsx` | Import it; render the `import.meta.env.DEV`-gated `<Agentation endpoint="http://localhost:4747" />` inside the `<body>` of the root layout. |

   Confirm the exact insertion point with the user, show the diff, then save. Never blind-edit.
5. **Finish.** Tell the user to: **restart Claude Code** (so it loads the `agentation` MCP), start the
   **dev server**, and verify with `npx agentation-mcp doctor`. Then they can annotate.

## 2. Watch / review mode (a live session)

1. **Preflight.** Confirm the `agentation_*` MCP tools are available (if not → restart Claude Code;
   `npx agentation-mcp doctor`). Confirm the dev server is up and the toolbar shows bottom-right.
   Then call `agentation_list_sessions`: **connected but 0 sessions ⇒ the `endpoint` prop is missing
   from the wired `<Agentation />` or the browser tab is stale** — fix the wiring / reload before
   handing off, rather than waiting on a watch that will never see anything.
2. **Default to the batch contract.** Open with: *"Annotate everything you want changed, then come back
   and say 'done' — I'll pull the whole batch and apply the fixes."* When they say done, call
   `agentation_get_all_pending`. This lets the user mark up the whole screen and hand off a reviewed
   batch, instead of being interrupted mid-thought.
   - **Hands-free is opt-in.** Only call `agentation_watch_annotations` (which blocks silently for
     minutes and picks notes up one at a time) if the user explicitly asks to "watch" / go hands-free.
3. **Set expectations explicitly** (so the browser side isn't a silent black box): notes flip
   **acknowledged → resolved** in the toolbar as you work; fixes land via **HMR** — *refresh to see
   them*; each resolved note carries a **one-line summary** of the change.
4. **Run the loop** (also encoded in `.claude/rules/react-annotate.md`): for each annotation →
   `agentation_acknowledge` → locate the code (source path if present, else grep selector / component /
   nearby text) → make the fix per project conventions → `agentation_resolve` with a one-line summary
   (or `agentation_dismiss` with a reason / `agentation_reply` to ask). In hands-free, loop on
   `agentation_watch_annotations` until the user stops.
5. **On close.** If the project has memory enabled, write a short MemPalace summary to the project wing
   (resolved annotations, files touched, deferred items) before the closing summary.

## 3. Status mode

- Print `.annotate` from `kit.config.json`; run `npx agentation-mcp doctor`; if the MCP is live, call
  `agentation_list_sessions` to show active annotation sessions.

## Rules

- **Consent-gated + reversible.** Ask before installing, before editing the app entry (show the diff),
  and before registering the MCP. Setup is idempotent — re-running is safe.
- **Don't vendor Agentation.** Only ever `install` it into the user's project; never copy its source
  into the kit (PolyForm Shield noncompete).
- **Be honest about limits** every time: dev-only, no prop/state values (grep to the file), RSC degrades
  to a selector. Don't claim file:line is guaranteed.
- **Claude-only scope.** If asked about Cursor/Codex, point to Agentation's own MCP/`npx add-mcp`; the
  kit doesn't wire them.
- Don't reimplement Agentation's Next-only `/agentation` skill — this skill's job is the broader
  framework coverage (Vite + React Router) plus the Claude-kit loop, rule, and MCP wiring.
