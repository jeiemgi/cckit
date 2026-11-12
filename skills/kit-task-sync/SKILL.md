---
name: kit-task-sync
description: Query GitHub issues (+ Projects v2 if enabled) and print a status table grouped by Role. Flags blocked items and items missing a board entry.
when_to_use: "What's the state of work?", "what's blocked?", "show me the board", or the start of any chapter that needs current ground truth instead of a stale snapshot.
---

# kit-task-sync

Plugin-direct skill — the script resolves from `${CLAUDE_PLUGIN_ROOT}`.

## What it does

Runs `${CLAUDE_PLUGIN_ROOT}/scripts/task-sync.sh` — pure bash over `gh` CLI + jq. Reads
`.claude/kit.config.json` (from the working directory) for the repo and board. Read-only on
GitHub — it never mutates the board.

## Execution

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/task-sync.sh" [--role <Name>] [--milestone <label>] [--plan]
```

`--plan` appends `effort plan` (the session-fit view of open efforts) under the board.

### Dashboard flags

For a TUI or statusline that polls the board, not for answering "what's the state of work?":

| Flag | Effect |
| --- | --- |
| `--json` | one JSON object: `roles`, `unassigned`, `blocked`, `stale`, `mergeQueue` |
| `--write` | write that object atomically to `<git-common-dir>/kit-sync-cache.json`; a failed or partial fetch leaves the file untouched |
| `--cached [TTL]` | print the cache with no `gh` call while it is younger than TTL seconds (default 60), else refresh it |
| `--watch [SECS]` | refresh the cache every SECS seconds (default 30), keeping the last good one when a fetch fails |

`--write`, `--cached` and `--watch` refuse `--role` / `--milestone` (exit 2). Writing the cache and
the `op.start` / `op.done` lines in `kit-events.jsonl` are the only local writes; GitHub is never mutated.

## Output format

Markdown table grouped by Role, sorted by Status (In Progress → Blocked → Todo → In Review → Done within 7 days), followed by:

```
**Blocked:** none ✓
**No board entry:** none ✓
**Stale (>14 days):** none ✓
```

## Rules

- Pure read — never mutate
- If `scripts/.project-ids.env` is missing and Projects v2 is enabled, prompt to run `${CLAUDE_PLUGIN_ROOT}/scripts/capture-project-ids.sh`
- bash 3.2+ compatible (macOS system bash)
