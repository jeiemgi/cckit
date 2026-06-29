---
title: Driving cckit from agents
description: cckit is agent-agnostic — any agent that can run a shell can drive the full lifecycle.
---

cckit is agent-agnostic. Claude Code is first-class (skills + slash commands), but any agent that can
run a shell can drive the full lifecycle. The contract lives in `AGENTS.md` at the repo root.

## Ground rules

- **Read state before acting.** `cckit sync --llm` returns the board as JSON. Decide from data.
- **One issue = one branch = one worktree = one PR.** `cckit start <issue>` creates the isolated
  worktree; do all work there; `cckit pr <issue>` opens the PR. Never commit to the base branch.
- **Structured output.** Append `--llm` to any verb for machine-readable (JSON) output.
- **Idempotent + safe.** Re-running a verb on an already-done step is a no-op, not an error.
- **Never invent paths or config.** Everything resolves from `cckit.config.json`.

## The agent loop

1. `cckit sync --llm` → pick an unblocked issue.
2. `cckit start <issue>` → enter the worktree it prints.
3. Implement; commit early and often.
4. `cckit pr <issue> "<summary>"` → open the PR; report the URL.
5. Stop. Merging is a human decision unless an approved plan says otherwise.

## Model endpoint

cckit shells out to whatever agent invokes it; it does not embed a model. For verbs that synthesize
text, the model endpoint is configurable via environment.
