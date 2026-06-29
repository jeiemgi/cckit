---
description: Export this kit project to the non-terminal Claude surfaces (#376). Flattens CLAUDE.md (+ inlined @.claude/rules) into claude.ai custom-instructions, copies knowledge/ into an upload-ready folder, verifies Cowork compat, and emits a support matrix. Acceptance: the same project runs in terminal / Cowork / claude.ai with no hand edits.
argument-hint: "[--verify] [--matrix] [--out DIR] [--dry-run]"
allowed-tools: Bash
---

# /kit-export-project — run the project on claude.ai + Cowork, no hand edits

A kit project runs on three Claude surfaces. **Terminal** and **Cowork** read `CLAUDE.md` + `.claude/`
natively — they need nothing from this command. **claude.ai Projects** have no filesystem: only a
"custom instructions" text box + uploaded "project knowledge". This command produces exactly those
two artifacts, and checks the project is portable.

## Tier model (#373)

- **Tier A = portable** — skills / rules / agents / commands; meaningful in Cowork AND claude.ai.
- **Tier B = CLI-only** — `statusline.sh` / `settings.json` / `hooks/` / `lib/`; need a terminal +
  filesystem. The export carries only tier-A semantics off-terminal; a tier-B file the project
  _requires_ is a portability defect `--verify` flags.

## What it writes (default `.kit-export/`)

| File                     | Use                                                                                                                             |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------------------- |
| `claude-instructions.md` | Flattened `CLAUDE.md` with `@.claude/rules/*` inlined (tier-A only) — paste into the claude.ai Project custom-instructions box. |
| `project-knowledge/`     | `knowledge/**` + tier-A `rules/` + `agents/` — upload as Project knowledge.                                                     |
| `SUPPORT-MATRIX.md`      | terminal / Cowork / claude.ai capability table, generated from the manifest.                                                    |

## Modes

- (no args) — full export to `.kit-export/` (or `--out DIR`).
- `--verify` — Cowork + claude.ai compat check only, writes nothing; rc 1 on a portability defect.
- `--matrix` — print the support matrix, write nothing.
- `--dry-run` — report what it would write, write nothing.

## Steps

1. Run the export (pass through `$ARGUMENTS`):

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/kit-export-project.sh" $ARGUMENTS
   ```

   (or `kit export $ARGUMENTS` — the CLI dispatches to the same canonical script.)

2. For a full export, tell the user the two manual steps claude.ai needs:
   - paste `.kit-export/claude-instructions.md` into the Project's custom-instructions box
   - upload `.kit-export/project-knowledge/` as the Project's knowledge

3. If `--verify` exits non-zero, surface the flagged tier-B-required / missing imports — those
   files silently no-op off-terminal; fix before relying on the non-terminal surfaces.

## Rules

- Bare URLs only in terminal output (no OSC 8).
- The export carries **only tier-A** semantics to claude.ai — a tier-B shim has no meaning without a
  filesystem. Run `--verify` to confirm the portable surface is self-sufficient.
- `/kit-doctor` runs the same `--verify` as a connection test — green there means this export is clean.
