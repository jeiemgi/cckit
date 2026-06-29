---
name: kit-onboard
description: Run the claude-kit two-tier onboarding interview — the wide-range GLOBAL profile (asked once in a lifetime, writes ~/.claude/kit.profile.<user>.json) and the per-PROJECT interview (one batched round, pre-filled from your profile + what's detected in this directory). Use AUTOMATICALLY when the user asks to onboard, set up the kit for the first time, "interview me", create my kit profile, configure a new project, or when /kit-init runs against a project with no kit profile yet. Pairs with /kit-add to stack modules (e.g. software) later.
when_to_use: First contact with the kit on a machine (no global profile yet), or starting a new project. Portable (Tier A) — runs in Claude Code, Cowork, and claude.ai Projects via AskUserQuestion.
allowed-tools: Bash, Read, AskUserQuestion
---

# kit-onboard — the two-tier interview (D11)

Two tiers. The ASKING is yours (AskUserQuestion). The DERIVING + WRITING is deterministic and
lives in the engine — never hand-edit config JSON; call the scripts.

Engine (under `${CLAUDE_PLUGIN_ROOT}`):
- `scripts/lib/kit-interview.sh --catalog TIER` — the question set (`global` | `project`).
- `scripts/lib/kit-interview.sh --render TIER --dir DIR` — same, with each `default` PRE-FILLED
  from the global profile + repo detection. **Render, don't read raw — the defaults are the point.**
- `scripts/kit-onboard.sh global  --answers FILE` — persist tier-1 to the global profile.
- `scripts/kit-onboard.sh project --answers FILE --dir DIR` — persist tier-2 (manifest-tracked).
- `scripts/kit-onboard.sh status` — has the global profile been created? (rc 1 = not yet)

## Tier 1 — global profile (ONCE in a lifetime)

1. Run `scripts/kit-onboard.sh status`. **If it reports a profile already exists, SKIP tier 1**
   entirely — the wide-range interview is once-ever. Go straight to tier 2.
2. Otherwise render the catalog: `scripts/lib/kit-interview.sh --render global`.
3. Ask the questions with **AskUserQuestion** — one batched round. For each question use its
   `header`, `question`, and `options` (mark the `recommended` option first, label it
   "(Recommended)"); seed the selection from `default`. Text questions (e.g. name) → free input.
4. Build an answers JSON `{ "<key>": "<chosen value>", ... }` (keys = each question's `key`), write
   it to a temp file, and persist: `scripts/kit-onboard.sh global --answers /tmp/kit-global.json`.

## Tier 2 — this project (batched, pre-filled)

1. Render: `scripts/lib/kit-interview.sh --render project --dir <project-dir>`. Defaults are already
   filled from the global profile (language, owner) and the directory (project name ← folder, etc.).
2. Ask with **AskUserQuestion** — one batched round, defaults pre-selected. Confirm or change.
3. Persist: `scripts/kit-onboard.sh project --answers /tmp/kit-project.json --dir <project-dir>`.
4. **The `software` question is a control answer, not a config field.** If the user answers
   `yes`, immediately run the **kit-add** flow for the software module (the software wizard:
   versioning / deploy / CI) — see the `/kit-add` command. If `no`, stop: it stays a free
   workspace, and they can run `/kit-add software` any time.

## Rules

- **Render before asking** — never invent question text or defaults; the catalog is the source.
- **One batched AskUserQuestion round per tier** — don't drip-feed.
- **Skip tier 1 if a profile exists** (`kit-onboard.sh status`). Tier 2 always runs per project.
- The global profile lives OUTSIDE any project (`~/.claude/`); the project config is manifest-tracked
  (safe to update/uninstall later). Both are user-owned identity — the engine writes, never invents.
- Mode stays `guided` by default (local-first, D16): warnings, never blocks. Enforced is opt-in.
