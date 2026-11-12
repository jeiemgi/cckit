---
description: Stack a kit MODULE onto this project (e.g. `kit add software`) — turns a free workspace into a GitHub-managed island via a short wizard, without restructuring anything above it.
argument-hint: "<module>   (e.g. software, qa)"
allowed-tools: Bash, Read, AskUserQuestion
---

# /kit-add — stack a module onto this project

Modules are **apilables** (D1): a base project stays a free workspace until a module is added on
demand. Adding `software` is the "build me an app" moment — it writes THIS island's
`.claude/kit.config.json` (modules + wizard answers) and nothing above it (D4/D17). Adding `qa`
records how the project's review stack boots (see step 4). A module is
**identity, not files** (D14): the agents/skills come from the installed plugin singleton; kit-add
only writes config, manifest-tracked so it can be updated or removed cleanly.

Engine (under `${CLAUDE_PLUGIN_ROOT}`):
- `scripts/lib/kit-interview.sh --catalog <module>` — the module's wizard questions.
- `scripts/kit-add.sh <module> --answers FILE [--dir DIR]` — derive + persist (the four-beat machine).
- `scripts/kit-add.sh <module> --set k=v ... ` — same, answers as flags.

## Steps

1. **Resolve the module** from `$ARGUMENTS` (default `software` if none given). Confirm a catalog
   exists: `scripts/lib/kit-interview.sh --catalog <module>` (non-zero rc = unknown module → tell
   the user which modules exist: look in `${CLAUDE_PLUGIN_ROOT}/modules/`).
2. **Render the wizard** (the catalog already carries each question's recommended `default`).
3. **Ask with AskUserQuestion** — one batched round. For each question use its `header`,
   `question`, and `options`; put the `recommended` option first and label it "(Recommended)".
   The kit recommends; the user decides.
   A `text`, `list` or `pairs` question has no `options`: ask it as free text and pass the answer
   through as typed. `list` takes comma-separated items (`QA_EMAIL, QA_PASSWORD`); `pairs` takes
   comma-separated `NAME=value` (`WEB_PORT=3000, API_PORT=4000`).
4. **Persist** — build `{ "<key>": "<value>", ... }` to a temp file and run
   `scripts/kit-add.sh <module> --answers /tmp/kit-<module>.json` (add `--dir` if not in the
   island root). For software the wizard covers **versioning** (GitHub vs local git),
   **deploy** (none / Vercel / other), and **CI** (GitHub Actions / none).
   For `qa` the wizard covers the **stack command**, the **port env vars** it honours (with a base
   port each), one **readiness** probe per service, the **review route**, and the **names** of the
   test-credential env vars. The answers land under `qa` in the config; a missing stack command
   fails the add and writes nothing.
   When the config already exists and the kit does not track it (every `cckit init` config), the
   script prints the diff and asks `overwrite? [y/N]` on stdin — an unattended run
   (`KIT_ASSUME_YES`) keeps the file. Show the user the proposed block, and on their yes run
   `printf 'y\n' | scripts/kit-add.sh <module> --answers <file>`.
5. **Report** what changed: the island config path, `modules`, and the resolved github/deploy/ci.
   Note the workspace above was untouched, and that `/kit-task-start` etc. now apply here.

## Rules

- **Idempotent** — running it again with the same answers is a no-op; `modules` never duplicates.
- **Never hand-edit `kit.config.json`** — always go through `kit-add.sh` so the manifest stays true.
- **Writes only into this island** — never above the project level without an explicit confirm
  (that's `kit-promote`'s job, not kit-add).
- **Credentials by NAME, never value** — `qa` asks which env vars hold the test credentials. An
  answer carrying a value (`QA_PASSWORD=...`) is refused and nothing is written; never ask the user
  for the value itself.
- **Config path** — a root `cckit.config.json` in the island is the file written; otherwise
  `.claude/kit.config.json`.
- Honors `KIT_DRY_RUN` (preview) and `KIT_ASSUME_YES` (accept recommended defaults, for batch/CI).
