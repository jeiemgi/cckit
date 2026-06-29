# MemPalace — Persistent Memory Protocol

> Optional. Active only because this project enabled memory at `/kit-init`.
> Requires the MemPalace MCP server + `mempalace` CLI. If you don't use MemPalace,
> delete this file and the `SessionStart`/`Stop`/`PreCompact`/`SessionEnd` hooks in `.claude/settings.local.json`.

## Wing architecture

One wing per project. This project uses **`{{WING}}`**. Never write to another project's wing.

## Room map ({{WING}} wing)

| Room           | What goes there                             |
| -------------- | ------------------------------------------- |
| `decisions`    | ADRs, product decisions, decision log       |
| `architecture` | Design system, brand, screens, design brief |
| `planning`     | Implementation plans, ops plans             |
| `technical`    | API routes, schema, engineering sessions    |
| `problems`     | Bug investigations, incident notes          |
| `general`      | Everything else                             |

## On session start

1. Call `mempalace_status` — loads the overview
2. Working on a topic: `mempalace_search "<topic>" wing={{WING}}` for past context

## Before answering about past decisions / prior sessions / existing work

- Call `mempalace_search` first — do not rely solely on the context window

## After meaningful work (decisions, discoveries, conclusions)

- `mempalace_add_drawer` — verbatim content, `wing={{WING}}`, pick a room above
- `mempalace_kg_add` — entity triples (subject / predicate / object)

## On session close

When the user says to close or end the session ("close session", "cierra la sesión", "we're done"),
write the session to memory **before** the closing summary — every time:

1. `mempalace_diary_write` (own wing `agent-<name>`, topic = the session) — an AAAK summary: what was
   done, the decisions, and what's still open.
2. `mempalace_add_drawer` (`wing={{WING}}`, room `decisions`) — verbatim record of the key decisions.
3. `mempalace_kg_add` — triples for any notable new entities/facts.
4. **If there is unsynced local work** (dirty tree, unpushed commits, stashes), write a terse
   "resume here" follow-up: `mempalace_add_drawer` (`wing={{WING}}`, room `planning`) with the branch,
   what's uncommitted/unpushed, the next step, and any open PR/issue refs — so the next session resumes
   cheaply instead of re-deriving context. Prefer committing/pushing the work; the drawer is for what
   genuinely can't land yet.

(The `Stop` hook files the raw transcript; the `SessionEnd` hook is the safety net that captures
unsynced work if you forgot step 4 — this is the curated, decision-level summary.)

## Specialist agent protocol

Each agent has its own diary wing (`agent-<name>`) for session notes; all project content saves to `wing={{WING}}`.

### On wake-up (every specialist agent)

1. `mempalace_diary_read` (own wing) — recall last session
2. `mempalace_search "<topic>"` in its room — pull relevant context

### After significant work

- `mempalace_diary_write` (own wing, topic = what was done)
- `mempalace_add_drawer` (`wing={{WING}}`, relevant room)

## CLI commands (`mempalace` 3.3.5)

The MCP tools above are for in-session reads/writes. Use the **CLI** for bulk ingest, maintenance, and automation. Always preview destructive ops with `--dry-run` before `--apply`.

| Task                                                       | Command                                                          |
| ---------------------------------------------------------- | ---------------------------------------------------------------- |
| Ingest this project's code/docs                            | `mempalace mine <dir> --wing {{WING}}`                           |
| Ingest chat exports (Claude Code / ChatGPT / Slack)        | `mempalace mine <dir> --mode convos --wing {{WING}}`             |
| Split concatenated transcript mega-files (before `mine`)   | `mempalace split <dir>`                                          |
| Search from the shell                                      | `mempalace search "query" --wing {{WING}} --room <room> --results N` |
| Load wake-up context (~600–900 tokens)                     | `mempalace wake-up --wing {{WING}}`                              |
| Palace overview                                            | `mempalace status`                                               |
| Prune drawers for deleted/moved/gitignored sources         | `mempalace sync --wing {{WING}} --dry-run` → `--apply`           |
| Compress drawers via AAAK (~30×)                           | `mempalace compress --wing {{WING}} --dry-run`                   |
| Show MCP setup command                                     | `mempalace mcp`                                                  |

Correct-option notes:

- `mine` defaults to `--mode projects`; pass `--mode convos` for chat exports. `--extract exchange` (default) or `--extract general` controls convo extraction. `--wing` defaults to the directory name — **always pass `--wing {{WING}}`** so this project's memory stays in one wing.
- `search` (CLI) uses `--wing` / `--room` / `--results`; the MCP `mempalace_search` tool uses `wing` / `room` / `limit` instead.
- `sync` is dry-run by default; `--apply` requires `--wing` (or a project root) as a guard against mass deletion.

## MCP vs CLI — which to use

| Case                                          | Use                                                        |
| --------------------------------------------- | ---------------------------------------------------------- |
| In-session granular **read**                  | MCP `mempalace_search` / `kg_query` / `traverse`           |
| In-session granular **write**                 | MCP `mempalace_add_drawer` / `kg_add` / `diary_write`      |
| Bulk ingest a directory or chat export        | CLI `mempalace mine`                                       |
| Maintenance (prune, compress)                 | CLI `mempalace sync` / `compress`                          |
| Automation (session start / stop / compaction)| Hooks → CLI (below)                                        |

## Hooks (scaffolded into `.claude/settings.local.json`)

- **SessionStart** → `mempalace wake-up --wing {{WING}}` — injects palace context at session start. Uses `wake-up --wing` (explicit) rather than `mempalace hook run --hook session-start`, which derives the wing implicitly and could file into the wrong wing.
- **Stop** → files the finished session into `wing={{WING}}` (`mempalace mine … --mode convos`).
- **PreCompact** → safety-net sweep before context compression.
- **SessionEnd** → `mempal_followup.sh`: if the current branch has **unsynced work** (dirty tree or
  unpushed commits), writes a terse "resume here" note and mines it into `wing={{WING}}` so an abrupt
  close doesn't lose it. Silent no-op when the tree is fully synced. This is the safety net for the
  agent-driven step 4 above.

All four are safe no-ops when the `mempalace` CLI is not installed.
