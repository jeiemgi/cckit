---
description: Manage suggested scheduled routines for this project — browse the catalogue, accept one or more, or remove them. The kit SUGGESTS; you decide; nothing is wired without your opt-in.
argument-hint: '[list | accept <id> | remove <id> | verify]'
allowed-tools: Bash, Read, AskUserQuestion
---

# /kit-routines — suggested routine catalogue

Plugin-direct command. Engine at `${CLAUDE_PLUGIN_ROOT}/scripts/kit-routines.sh`.

The kit ships a set of **suggested routines** (briefing, board sweep, GC, knowledge-lint,
kit-wire-check, security-sweep). Each is an OS cron job scoped to this project. Nothing is
created without your explicit opt-in.

## Steps

### No argument (or `list`)

1. Run `scripts/kit-routines.sh list` and display the catalogue table.
2. For each routine mark it `accepted` (already in crontab) or `available`.
3. Offer to accept any available ones via `AskUserQuestion` — one batched ask.
4. For each accepted id run `scripts/kit-routines.sh accept <id>`.
5. Report what changed.

### `accept <id>`

Run `scripts/kit-routines.sh accept <id>` (interactive confirm unless `KIT_ASSUME_YES`).
Reports the cron expression and command that will be added before doing anything.

### `remove <id>`

Run `scripts/kit-routines.sh remove <id>`.
Removes the crontab entry and clears the id from `kit.config.json`.

### `verify`

Run `scripts/kit-routines.sh verify`. Reports which accepted routines have their cron entry
installed and flags any that are missing (drift from a manual crontab edit or machine change).

## Catalogue

| ID               | Cadence      | Cost   | Description                                         |
| ---------------- | ------------ | ------ | --------------------------------------------------- |
| `briefing`       | Mon–Fri 8am  | low    | Morning briefing — open issues, board state         |
| `board-sweep`    | Mon–Fri 8:30 | low    | Orphan issues, stale In-Progress, merged-not-closed |
| `gc`             | Mon 9am      | low    | Repo GC dry-run — merged branches/worktrees report  |
| `knowledge-lint` | Tue 9am      | low    | knowledge/ frontmatter + INDEX + live refs          |
| `kit-wire-check` | Mon 10am     | low    | Kit wiring drift (statusline shim, hooks, crons)    |
| `security-sweep` | Wed 9am      | medium | Dep CVE scan (npm audit / pip-audit / cargo audit)  |

## Rules

- The kit NEVER auto-accepts a routine — every opt-in requires an explicit user confirm.
- `kit-remove` (uninstall) calls `remove-all` automatically — leaving no orphan crons.
- `kit-wire --check` (SessionStart self-heal) calls `verify` — reports drift if a cron
  entry disappears from the crontab without a `kit-routines remove`.
- Accepted routine ids are stored in `kit.config.json` `.routines[]` (manifest-tracked).
- Routines requiring the `software` module (`board-sweep`, `gc`, `security-sweep`) show a
  note when that module is not active for this project.
