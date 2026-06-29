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
```
