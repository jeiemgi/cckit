# Using claude-kit

[English](usage.md) · [Español](usage.es.md)

[← README](../README.md) · **Usage** · [Agents & orchestration →](agents.md) · [Reference](reference.md)

## What you get

| Layer           | What it is                                                                                                                                                                                                                                              |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Commands        | `/kit-init` — scaffold `.claude/` from a profile (`--dry-run` previews) · `/kit-customize` — add/edit/delete agents, wire skills + tools, lint, build custom profiles · `/kit-contribute` — submit agents/skills/profiles/requests back upstream as PRs |
| Agents          | Role sub-agents (PM, Tech Lead, Designer, DevOps, Backend, Frontend, QA, Security, Researcher, Editor, Analyst, Generalist, n8n) — see [Agents & orchestration](agents.md)                                                                              |
| Workflow skills | `task-new` · `task-start` · `task-pr` · `task-pr-merge` · `task-pr-auto` · `task-sync` · `task-close` · `morning-briefing`                                                                                                                              |
| Content skills  | `copywriting` — conversion copy for landing/marketing pages (in the `content` profile)                                                                                                                                                                  |
| Universal skill | `karpathy-guidelines` — LLM coding-pitfall guardrails, in **every** profile                                                                                                                                                                             |
| Stack skills    | `feature-build-refine` · `supabase-patterns` — **self-gating** (see [Reference](reference.md#stack-gated-skills-build-conventions))                                                                                                                     |
| SDD             | `speckit` — install/identify Spec Kit + drive spec→plan→tasks→implement (opt-in)                                                                                                                                                                        |
| Rules           | Communication style · task management · plan format · design routing · MemPalace                                                                                                                                                                        |
| Workflow        | Issue → branch → PR → merge → close, all through GitHub (+ optional Projects v2)                                                                                                                                                                        |
| Memory          | Optional MemPalace wiring (SessionStart/Stop/PreCompact hooks) — off by default                                                                                                                                                                         |

## Profiles

| Profile      | Agents                                                           | For                         |
| ------------ | ---------------------------------------------------------------- | --------------------------- |
| `software`   | pm, tech-lead, designer, devops, backend, frontend, qa, security | Software products           |
| `content`    | pm, editor, designer, researcher                                 | Writing / editorial / brand |
| `research`   | pm, researcher, analyst                                          | Investigation + analysis    |
| `automation` | pm, n8n, generalist                                              | n8n / workflow automation   |
| `minimal`    | pm, generalist                                                   | Lean projects               |

Pick one at init; everything else (roles, milestones, plan format) follows from it. Edit
`.claude/kit.config.json` afterward to adjust.

## Project structure & the per-project model

claude-kit is **per project**: run `/kit-init` inside each project so it gets its own self-contained
`.claude/`. In a workspace or monorepo, initialize **each project separately** rather than once at the
root — `/kit-init` detects whether you're in a single project or a parent of several and recommends
accordingly.

> **Where this is heading (v2):** a single workspace-root "project OS" with a config cascade, modes,
> and stackable modules is in progress — see [claude-kit as a workspace OS](workspace-os.md). The
> per-project model on this page is the **current, shipping** one.

Why per-project:

- **Traceability via MemPalace** — each project maps to its own memory **wing**, so decisions, plans,
  and agent diaries are tracked per project and never bleed across them.
- **Self-contained** — the project's agents, skills, rules, and `kit.config.json` travel with the repo.
  Commit `.claude/` and your team shares the exact same setup.

Recommended layout:

```
your-project/
  CLAUDE.md              # entry point — points to .claude/
  .claude/               # agents · skills · rules · kit.config.json · settings.local.json
  docs/plans/            # implementation / ops plans (per the plan-output-format rule)
  scripts/               # kit helpers (setup-labels, setup-milestones, task-sync, …)
  …your code…
```

## Scaffold a project — `/kit-init`

After [installing](../README.md#install), run `/kit-init` in any project. It asks for profile, repo,
board, memory, and language, then scaffolds `.claude/` + `CLAUDE.md`. During onboarding it also runs an
**opt-in tool setup** — verifying `gh` auth and (with your consent) registering MemPalace or
authenticating `gws`, explaining each before touching anything.

Onboarding through the `claude` CLI (a real, re-timed session):

![Onboarding via the claude CLI](media/kit-onboarding.gif)

The interactive `/kit-init` with test values — **illustrative re-creation** (the answer chips are
mocked; the scaffold output below them is real `init.sh`):

![claude > /kit-init with test values](media/kit-init.gif)

## Preview before scaffolding (dry run)

See exactly which files a profile would write — without creating anything:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/init.sh" --profile software --name "My App" --dry-run
```

![kit-init --dry-run printing the scaffold plan](media/kit-dry-run.gif)

## Customize a scaffolded project — `/kit-customize`

Run `/kit-customize` any time after init (it also activates automatically when you ask to
create / edit / delete an agent):

- **add, edit, or delete an agent** — from a kit template or a fresh custom one
- **wire skills + tools** onto an agent (names are resolved first, so nothing is invented)
- **search / suggest skills** for your profile (via `find-skills`)
- **lint** your agents (frontmatter, tool/skill names, no leftover template tokens)
- **build a custom profile** — pick a preset or assemble your own, saved to `~/.claude/kit-profiles/`
  for reuse

## Run without the plugin

The engine is a plain bash script. The kit ships from `packages/claude-kit-plugin/` inside the
standalone `jeiemgi/cckit` repo — clone it and run the
script directly:

```bash
git clone https://github.com/jeiemgi/cckit ~/.cckit
cd /path/to/your/project
~/.cckit/scripts/init.sh --profile software --repo me/my-app --name "My App"
```
