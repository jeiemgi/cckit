---
name: kit-task-sync
description: Query GitHub issues (+ Projects v2 if enabled) and print a status table grouped by Role. Flags blocked items and items missing a board entry.
when_to_use: "What's the state of work?", "what's blocked?", "show me the board", or the start of any chapter that needs current ground truth instead of a stale snapshot.
---

# kit-task-sync

Plugin-direct skill — the script resolves from `${CLAUDE_PLUGIN_ROOT}`.

## What it does

Runs `${CLAUDE_PLUGIN_ROOT}/scripts/task-sync.sh` — pure bash over `gh` CLI + jq. Reads
`.claude/kit.config.json` (from the working directory) for the repo and board. Read-only —
never mutates state.

## Execution

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/task-sync.sh" [--role <Name>] [--milestone <label>]
```

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
