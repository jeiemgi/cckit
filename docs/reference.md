# Reference

[English](reference.md) · [Español](reference.es.md)

[← Agents & orchestration](agents.md) · **Reference** · [Usage](usage.md) · [README](../README.md)

## How it works

```
claude-kit/
  .claude-plugin/        plugin.json + marketplace.json   (delivers /kit-init, /kit-customize, /kit-contribute)
  commands/kit-init.md   the /kit-init slash command
  skills/
    kit-customize/       /kit-customize — add/edit/delete agents, wire skills/tools, lint, profiles
    kit-contribute/      /kit-contribute — submit agents/skills/profiles/requests upstream as PRs
  profiles/*.json        which agents/skills/rules/roles/milestones per profile
  templates/             {{VARS}} + <!-- IF:FLAG --> source files
    CLAUDE.md.tmpl  kit.config.json.tmpl
    agents/  skills/  rules/  hooks/  settings/
  scripts/
    init.sh              substitution + conditional engine (supports --dry-run)
    lib/kit-config.sh    loads .claude/kit.config.json -> KIT_* env (used by skills)
    lib/gh-project.sh    Projects v2 GraphQL helpers
    setup-labels.sh  setup-milestones.sh  capture-project-ids.sh  task-sync.sh
```

`init.sh` reads the chosen profile, substitutes project values into the templates, resolves
`<!-- IF:MEMORY -->` / `IF:PROJECTS_V2` / `IF:PLANS` / `IF:DESIGN` blocks, and writes a
self-contained `.claude/` into the target. Skills read live project values from
`.claude/kit.config.json` at runtime, so there's one source of truth per project.

## What's configurable per project

`.claude/kit.config.json` carries every project-specific value:

- `project` — name, slug, owner, language
- `github` — repo, owner, Projects v2 on/off + board number
- `roles`, `milestones` — from the profile, editable
- `plans` — format (`mdx` / `markdown` / `none`) + directory
- `memory` — MemPalace on/off + wing
- `local` — local model layer on/off + port + model (see below)

## Stack-gated skills (build conventions)

Build conventions are **not** mandatory rules — they are skills that **self-activate only when
their technology is detected in the project's `package.json`**:

| Skill | Activates when | Covers |
| ----- | -------------- | ------ |
| `feature-build-refine` | `@refinedev/*` present | Next.js + Supabase + RefineDev feature/form/page architecture |
| `supabase-patterns` | `@supabase/supabase-js` present | three-client model, server-action auth guard, RLS-first access |

If the tech isn't in the stack, the skill simply doesn't apply. Add more the same way — one
self-gating skill per technology. Nothing is forced across the board.

## Spec-Driven Development (opt-in)

Enable with `--speckit on` (or at the `/kit-init` prompt). The `speckit` skill installs or
identifies [Spec Kit](https://github.com/github/spec-kit), runs a Stack Interview, and drives the
`specify → clarify → plan → tasks → analyze → implement` lifecycle with review gates. Any matching
stack skill becomes the Spec Kit `feature-module.md` override automatically.

## Local model layer (opt-in)

Run the kit's NL chores — digest, summarize, classify, draft — on a **local model** at $0 API
cost, via Apple's MLX stack. Any agent/hook sources `scripts/lib/kit-local.sh` and calls
`kit_local_chat "<system>" "<prompt>"`; if the server is down the call returns non-zero and the
caller falls back to its normal path (never blocks, alive-check is 1s).

The easy path: enable at init with **`/kit-init --local on`** — it writes the `.local` config
block, scaffolds the SessionStart status hook, and lists the setup command in the next steps.
**`kit-doctor`** then sets the layer up end to end (#313): verifies Apple silicon, installs
`mlx-lm` via `uv tool install` (isolated venv, PEP 668-safe; fallback `pipx` — never plain
`pip`, which fails against Homebrew's externally-managed python), and starts `mlx_lm.server`
in background with a port health check (first run downloads the model, ~4.5 GB). `--dry-run`
stays 100% read-only. While the layer is enabled but down, every session start prints a notice
until it's up or you dismiss it (`kit-doctor --dismiss-local`, or `KIT_LOCAL_DISMISS=1`); a
dismiss sticks until the next x.y kit update.

Manual setup (Apple silicon):

```bash
uv tool install mlx-lm   # fallback: pipx install mlx-lm
mlx_lm.server --model mlx-community/Qwen3-8B-4bit --port 8080
```

Or enable later in `.claude/kit.config.json` (then re-run `/kit-init --upgrade --local on` to add
the hook):

```json
"local": { "enabled": true, "port": 8080, "model": "mlx-community/Qwen3-8B-4bit" }
```

When the server is alive, the `kit-local-status.sh` SessionStart hook prints one banner line
(`local: Qwen3-8B-4bit viva @ :8080`) — silence means the layer is off. `KIT_LOCAL_ENABLED`,
`KIT_LOCAL_PORT`, `KIT_LOCAL_MODEL`, `KIT_LOCAL_TIMEOUT` env vars override the config. The default
model needs ~5 GB RAM; pick a smaller one (e.g. `Qwen3-4B-4bit`) on tighter machines.

## Pre-push gate (opt-in)

Enable with `--prepush "<command>"` at init (e.g. `--prepush "pnpm -w build"`). It installs a
`PreToolUse(Bash)` hook that runs `<command>` before every `git push` and **blocks the push if the
command fails**. It's **self-passing**: it only acts on `git push`, and projects that don't opt in
(or have an empty command) are never blocked. Configurable later via `.prePush` in
`.claude/kit.config.json`.

## Requirements

- `gh` (authenticated), `jq`, `perl`, `git`, bash 3.2+ (macOS system bash is fine)
- `/kit-init` runs an **opt-in tool setup** during onboarding — for each tool it explains the purpose
  and installs/authenticates only with your consent:
  - **`gh`** — verifies `gh auth status` and offers `gh auth login` (required for the task/PR workflow)
  - **MemPalace** — only if you enable memory; registers the `mempalace` MCP or guides installing the
    `mempalace-mcp` runtime. Memory stays dormant (never errors) until it's present.
  - **`gws`** (Google Workspace CLI) — only if you work with Google Docs/Sheets/Slides/Drive/Gmail;
    offers `gws auth login`. Skipped otherwise.

## Attribution

`karpathy-guidelines` is vendored (MIT) from
[multica-ai/andrej-karpathy-skills](https://github.com/multica-ai/andrej-karpathy-skills)
(© forrestchang), derived from Andrej Karpathy's notes on LLM coding pitfalls.
