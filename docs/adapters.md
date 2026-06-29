# Adapters — the agnostic core and its agent layers

cckit is split in two so that **any** coding agent can drive it, while a specific agent (Claude
Code) gets a first-class, native experience. Understanding this split is the key to extending
cckit to a new agent.

## The agnostic core

The core is pure bash + the standard toolchain (`git`, `gh`, `jq`, `tmux`). It owns every
operation — the GitHub work lifecycle, efforts, worktrees, orchestration, garbage collection — and
nothing in it is specific to any agent.

| Path | Role |
| --- | --- |
| `bin/cckit` | the CLI dispatcher — one entrypoint for every verb |
| `scripts/lib/*.sh` | the operations (start/pr/close, effort, worktree, gc, orchestrate, ...) |
| `scripts/*.sh` | the runnable ops (publish, migrate, doctor, digest, ...) |
| `cckit.config.json` | the only source of repo/owner/base-branch/config — nothing is hardcoded |

The contract the core exposes to agents is in [`AGENTS.md`](../AGENTS.md): every verb, its args, and
its `--llm` (JSON) output. An agent that can run a shell and parse JSON can drive the whole
lifecycle through this contract alone. The core never assumes a particular agent is calling it.

## Adapter one — Claude Code

The Claude adapter is the native layer that makes cckit feel built-in inside Claude Code. It is a
thin shell over the core — it adds discovery and ergonomics, never a second implementation of an
operation.

| Path | Role |
| --- | --- |
| `.claude-plugin/plugin.json` | the Claude Code plugin manifest (install entrypoint) |
| `commands/*.md` | slash commands (`/kit-*`) that front the core verbs |
| `skills/*` | skills that teach Claude how + when to run each operation |
| `templates/{agents,hooks,rules,skills,settings}` | what `cckit init` scaffolds into a project's `.claude/` |

Every command/skill ultimately calls a core verb or `scripts/lib` function. There is one
implementation of each operation (in the core); the adapter only routes Claude to it. This is why a
fix in the core is a fix for every agent at once.

## Future adapters

Any other agent (Codex, Copilot, Antigravity, a custom model) is a **future adapter** over the same
core. An adapter is whatever that agent needs to discover and call the verbs — at minimum, the
agent reads `AGENTS.md` and shells out with `--llm`. No adapter re-implements an operation; they all
target the one core contract. Deep per-agent adapters (native command palettes, richer prompts) are
follow-ups; the agnostic CLI contract is the floor every agent already stands on.

## Why the split

- **One source of truth.** An operation lives once, in the core. No drift between "the Claude way"
  and "the CLI way".
- **Portable.** The core has no agent dependency, so cckit runs in CI, a cron job, or a bare
  terminal — not only inside an agent.
- **Open to any agent.** Adding an agent is writing an adapter, not forking the kit.
