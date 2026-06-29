---
description: Browse claude-kit's own documentation from inside Claude Code. Use to open the kit docs, read the usage / agents / reference / contributing guides, or get a navigable index — bilingual (EN/ES), with prev/next navigation. Triggers — "kit docs", "claude-kit documentation", "open the kit guide", "how do I use the kit".
argument-hint: "[readme|usage|agents|reference|contributing] [es]"
allowed-tools: Read, Glob
---

# /kit-docs — browse the claude-kit docs

The kit's documentation ships inside the plugin at `${CLAUDE_PLUGIN_ROOT}`. Use this to read and
navigate it without leaving Claude Code. These docs are a **sequence** — readme → usage → agents →
reference → contributing — so always offer prev/next.

## Steps

1. **Resolve language.** Default to the user's working language. If `$ARGUMENTS` contains `es` (or the
   user is writing Spanish), use the `.es.md` variants; otherwise the English `.md`.

2. **Doc map** (paths relative to `${CLAUDE_PLUGIN_ROOT}`):

   | Key | EN | ES | What |
   | --- | -- | -- | ---- |
   | `readme` | `README.md` | `README.es.md` | overview · install · update · best practices · stack |
   | `usage` | `docs/usage.md` | `docs/usage.es.md` | what you get, profiles, per-project model, `/kit-init`, `--dry-run`, `/kit-customize`, demos |
   | `agents` | `docs/agents.md` | `docs/agents.es.md` | orchestrator → sub-agent model, 13-agent table, mermaid diagrams |
   | `reference` | `docs/reference.md` | `docs/reference.es.md` | how it works, config, stack skills, Spec Kit, pre-push gate, requirements |
   | `contributing` | `CONTRIBUTING.md` | `CONTRIBUTING.md` | submit agents/skills/profiles/requests upstream |

3. **No key in `$ARGUMENTS`** → print the **index**: each doc as a row (key + one-line description) in
   the order above, and tell the user to run `/kit-docs <key>` to open one.

4. **A key given** → `Read` the resolved file from `${CLAUDE_PLUGIN_ROOT}` and present it:
   - If the user asked a specific question, surface the **relevant section** + its path — don't dump the
     whole file.
   - Otherwise render the doc (keep mermaid/code blocks fenced as-is; for long docs, lead with the
     section headers so they can jump).
   - End with a **nav footer**: `← Prev: /kit-docs <prev>` · `Index: /kit-docs` · `Next: /kit-docs <next> →`
     using the sequence order (readme → usage → agents → reference → contributing).

5. Mention the same page is on GitHub if they prefer the browser (link the repo path).

## Rules

- Read only from `${CLAUDE_PLUGIN_ROOT}` (the installed kit) — never the user's project files.
- Unknown key → show the index instead of erroring.
- Keep it navigable: every response ends with how to reach the previous and next doc.
