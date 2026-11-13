---
description: Onboarding preflight — check deps (Homebrew, git, gh, jq, perl, node, pnpm), authenticate gh + add scope:project, optionally set up SSH. Report-only unless run with --fix (or answered yes in a terminal); with --fix it installs what it can and pauses only for sudo password (Homebrew) and browser OAuth (gh auth login).
argument-hint: "[--fix] [--dry-run] [--no-install] [--dismiss-local]"
allowed-tools: Bash
---

# /kit-doctor — onboarding preflight

Run the kit-doctor script to check all dependencies and authentication required by claude-kit.

## What it checks

| Tier | Checks |
| ---- | ------ |
| Tier 0 | Homebrew (macOS bootstrap — installs if missing, requires sudo password) |
| Tier 1 | `git`, `gh` (≥2.29 for Projects v2), `jq`, `perl` — auto-installs via brew |
| Tier 2 | `node`, `pnpm`, `vercel` (if .vercel/ exists), `turbo`/`playwright` (dev deps only) |
| Agents | The CLI of each adapter the project selected (`adapters` in the config; absent means `claude`): `claude` and/or `codex`, present with its version or absent. Absent is a warning and a manual action — the doctor never installs an agent CLI |
| Integrations | One row per descriptor in `integrations/` whose config key is on: `mempalace CLI` (`.memory.enabled`) and `mlx-lm` (`.local.enabled`, Apple silicon only). `Lavish` (review pages) is on by default: with `.reviewPages.enabled` unset and neither `lavish-axi` nor `npx` on PATH its row is a skip — not installed, not a failure; with the key set to `true` it is a row like the others. A missing tool is installed by the shared runner (`scripts/lib/integration-install.sh`) from the descriptor's ordered candidates — never plain `pip`. Installs need consent recorded in `.cckit/consent`: `--fix` or a yes at the prompt records it; a run with neither (no terminal, no `--fix`) reports the tool missing and installs nothing; `--dry-run`/`--no-install` only report |
| Local | Only when `.local.enabled` — starts `mlx_lm.server` in background with a port health check (first run downloads ~4.5 GB) |
| Memory | Only when `.memory.enabled` — seeds the per-wing wake-up header (`.claude/mempal-identity.<wing>.txt`) and refreshes a stale session-start hook. Seed + refresh obey the consent guard: `--fix` applies them, `--dry-run`/`--no-install` only report |
| Auth | `gh auth status`, scope `project`, `git config user.name/email` |
| Repo | `github.baseBranch` vs the repo's GitHub default branch — a mismatch means `Closes #N` won't auto-close issues on GitHub-UI merges (report-only; `cckit pr-merge` already closes them explicitly) |
| Instruction files | The bytes `CLAUDE.md` + every `.claude/rules/*.md` without a `paths:` frontmatter load into every session, against Claude Code's 150k limit, and the three largest files. Warns over the limit (report-only; `scripts/instruction-budget-lint.sh --report` lists every file) |
| SSH | Optional: detect existing key; `KIT_DOCTOR_SSH=1` triggers guided ed25519 setup |

## Flags

- *(no flag)* — in a terminal it asks before installing. Run from Claude Code there is no terminal, so
  it is report-only: no package install, no `pnpm install`, no seeded or refreshed file, no server start
- `--fix` (alias `--yes`) — install what is missing and seed/refresh files without asking. Pass it only
  when the user asked for installs
- `--dry-run` — report only, touch nothing (no installs, no server start)
- `--no-install` — check + auth only, skip package installs
- `--agents` — only the agent-runtime rows; no installs, no network; exits 1 when a selected runtime is absent
- `--dismiss-local` — silence the "local layer down" SessionStart notice until the next x.y kit update (writes `.local.dismissed` to `kit.config.json`); session-only alternative: `KIT_LOCAL_DISMISS=1`

## Steps

1. Resolve the doctor script path: `${CLAUDE_PLUGIN_ROOT}/scripts/kit-doctor.sh`

2. Pass through any `$ARGUMENTS` (e.g. `--dry-run` or `--no-install`):

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/kit-doctor.sh" $ARGUMENTS
   ```

3. If the script exits non-zero (Tier 1 failures remain):
   - Surface the "Action required" items from the output
   - Tell the user to fix them and re-run `/kit-doctor`
   - Do not proceed with `/kit-init` until all Tier 1 checks pass

4. If all Tier 1 checks pass:
   - Report success
   - Point the user at the pointer the doctor prints on its last line: the local onboarding app at `$CCKIT_ADMIN_URL/onboarding` **only when it is actually reachable**, otherwise the public docs at `https://cckit.dev`. Do not hardcode `localhost:3001` — nothing serves it by default.

## Rules

- Never skip the preflight. `/kit-init` calls this automatically, but it can be run standalone.
- Bare URLs only in terminal output (Terminal.app does not support OSC 8 hyperlinks).
- The `--dry-run` flag makes the doctor read-only — safe to run in CI or before any changes.
- For SSH setup, the user must set `KIT_DOCTOR_SSH=1` explicitly — the doctor never generates SSH keys by default.
