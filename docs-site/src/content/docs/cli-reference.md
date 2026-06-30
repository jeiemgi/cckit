---
title: CLI reference
description: The cckit verbs.
---

cckit is a thin bash dispatcher over a git-mechanics bundle. Every verb is driven from
`cckit.config.json` — no org or repo is hardcoded. Append `--llm` for machine-readable output.

| Verb | Purpose |
| --- | --- |
| `cckit init` | Scaffold `cckit.config.json` + `.claude/` for this repo. |
| `cckit start <issue> [slug]` | Create an isolated worktree + branch for an issue. |
| `cckit pr <issue> <summary>` | Commit, push, and open the PR. |
| `cckit close <issue> <summary>` | Close the issue and mark it done. |
| `cckit sync` | Board state / what's unblocked. |
| `cckit plan-next` | Forward plan: inventory current skills/verbs/rules/docs and propose what to build next. |
| `cckit effort <new\|start\|pr\|close\|plan>` | The effort lifecycle. |
| `cckit orchestrate <a> <b> …` | Run N flows in parallel worktrees. |
| `cckit gc` | Prune merged branches + worktrees. |
| `cckit version` | The installed cckit version. |

### Structured output

Append `--llm` (or `--output=json`) to any verb for parseable output, so an agent can reason over
the result instead of scraping human text:

```bash
cckit sync --llm
cckit effort plan --llm
cckit plan-next --llm   # the forward plan as TOON rows {rank,area,proposal,next}
```

### Forward planning

`cckit plan-next` answers "given everything the kit can already do, what should we build next?" It
introspects the current capability surface (skills, verbs, rules, docs) and proposes a ranked,
grounded set of next efforts — rank 1 is always the mandatory docs + README step. It complements
`cckit plan`, which orders issues that already exist; plan-next proposes the ones that don't yet.
Run it from the cckit repo for a full inventory, or from a host project (it degrades to whatever docs
exist). Its output is human/orchestrator-facing only — never inject it into a monitored agent's
context. Pair it with the `/kit-plan-next` skill to hand a chosen item into `/kit-effort-new`.
