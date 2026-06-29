---
description: Onboarding preflight — check deps (Homebrew, git, gh, jq, perl, node, pnpm), authenticate gh + add scope:project, optionally set up SSH. Auto-installs everything it can; pauses only for sudo password (Homebrew) and browser OAuth (gh auth login).
argument-hint: "[--dry-run] [--no-install] [--dismiss-local]"
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
| Local | Only when `.local.enabled` — installs `mlx-lm` via `uv tool install` (fallback `pipx`, never plain `pip`) + starts `mlx_lm.server` in background with a port health check (first run downloads ~4.5 GB) |
| Auth | `gh auth status`, scope `project`, `git config user.name/email` |
| SSH | Optional: detect existing key; `KIT_DOCTOR_SSH=1` triggers guided ed25519 setup |

## Flags

- `--dry-run` — report only, touch nothing (no installs, no server start)
- `--no-install` — check + auth only, skip package installs
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
   - Remind the user the onboarding guide is at `http://localhost:3001/onboarding` (or `$CCKIT_ADMIN_URL/onboarding`)

## Rules

- Never skip the preflight. `/kit-init` calls this automatically, but it can be run standalone.
- Bare URLs only in terminal output (Terminal.app does not support OSC 8 hyperlinks).
- The `--dry-run` flag makes the doctor read-only — safe to run in CI or before any changes.
- For SSH setup, the user must set `KIT_DOCTOR_SSH=1` explicitly — the doctor never generates SSH keys by default.
