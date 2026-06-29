# AGENTS.md — driving cckit from an agent

cckit is agent-agnostic. Claude Code is first-class (skills + slash commands), but any agent that
can run a shell can drive the full lifecycle. This file is the contract.

## Ground rules

- **Read state before acting.** `cckit sync --llm` returns the board as JSON. Decide from data.
- **One issue = one branch = one worktree = one PR.** `cckit start <issue>` creates the isolated
  worktree; do all work there; `cckit pr <issue>` opens the PR. Never commit to the base branch.
- **Structured output.** Append `--llm` to any verb for machine-readable (JSON) output. Human
  (pretty) output is the default; agents should prefer `--llm`.
- **Idempotent + safe.** Re-running a verb on an already-done step is a no-op, not an error.
- **Never invent paths or config.** Everything resolves from `cckit.config.json`.

## Core verbs

| Verb | Purpose | LLM mode |
| --- | --- | --- |
| `cckit init` | scaffold config + `.claude/` | — |
| `cckit sync` | board state / what's unblocked | `--llm` → JSON |
| `cckit start <issue> [slug]` | isolated worktree + branch | `--llm` |
| `cckit pr <issue> <summary>` | commit + push + open PR | `--llm` |
| `cckit close <issue> <summary>` | close issue + mark done | `--llm` |
| `cckit effort plan` | session-fit work plan | `--llm` → JSON |
| `cckit orchestrate <a> <b> …` | run N flows in parallel worktrees | — |
| `cckit gc` | prune merged branches + worktrees | `--llm` |
| `cckit version` | the installed cckit version | `--llm` |

## The agent loop (reference)

1. `cckit sync --llm` → pick an unblocked issue.
2. `cckit start <issue>` → enter the worktree it prints.
3. Implement; commit early and often.
4. `cckit pr <issue> "<summary>"` → open the PR; report the URL.
5. Stop. Merging is a human/captain decision unless an approved plan says otherwise.

## Model endpoint

cckit shells out to whatever agent invokes it; it does not embed a model. For verbs that synthesize
text (digests, ingest), the model endpoint is configurable via environment — see `docs/` on
[cckit.dev](https://cckit.dev).
