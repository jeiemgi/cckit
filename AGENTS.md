# AGENTS.md — driving cckit from an agent

cckit is agent-agnostic. Claude Code is first-class (skills + slash commands), but any agent that
can run a shell can drive the full lifecycle. This file is the contract.

The two-layer split — an agnostic core (this contract) and per-agent adapters (Claude Code is
adapter one) — is described in [`docs/adapters.md`](docs/adapters.md).

## Ground rules

- **Read state before acting.** `cckit sync --llm` returns the board as JSON. Decide from data.
- **One issue = one branch = one worktree = one PR.** `cckit start <issue>` creates the isolated
  worktree; do all work there; `cckit pr <issue>` opens the PR. Never commit to the base branch.
- **Structured output.** Append `--llm` to any verb for machine-readable (JSON) output. Human
  (pretty) output is the default; agents should prefer `--llm`.
- **Idempotent + safe.** Re-running a verb on an already-done step is a no-op, not an error.
- **Never invent paths or config.** Everything resolves from `cckit.config.json`.
- **Hand off when you stop with unfinished work.** `cckit handoff "<what's pending, next step, refs>"`
  saves a local resume-here note; bare `cckit` (no verb) prints it so the next session resumes
  exactly where this one stopped.

## Core verbs

| Verb | Purpose | LLM mode |
| --- | --- | --- |
| `cckit init` | scaffold config + `.claude/` | — |
| `cckit sync` | board state / what's unblocked | `--llm` → JSON |
| `cckit start <issue> [slug]` | isolated worktree + branch | `--llm` |
| `cckit pr <issue> <summary>` | commit + push + open PR | `--llm` |
| `cckit close <issue> <summary>` | close issue + mark done | `--llm` |
| `cckit effort plan` | session-fit work plan | `--llm` → JSON |
| `cckit orchestrate <a> <b> …` | run N flows in parallel worktrees | — (use `--dry-run`) |
| `cckit autopilot [<a> …]` | unattended multi-flow: drive (or auto-pick) issues under a cap | — (use `--dry-run`) |
| `cckit gc` | report prunable branches + worktrees | `--llm` → JSON counts |
| `cckit version` | the installed cckit version | `--llm` |

Every verb accepts a global `--llm` (alias `--output=json`); verbs that produce a result emit a
single JSON object/array on stdout, with human text on stderr. Interactive/launch verbs
(`init`, `orchestrate`, `autopilot`) have no JSON result — use `--dry-run` to inspect their plan.

### Lifecycle ops (so autopilot runs unattended)

Every operation an unattended run needs is reachable through the one CLI:

| Verb | Purpose |
| --- | --- |
| `cckit scan` | detect the repo's stack + kit state (emits JSON) |
| `cckit doctor` | onboarding preflight (deps, gh auth) |
| `cckit update` | report whether the project is behind the installed cckit |
| `cckit migrate` | reshuffle an old kit layout to the current one |
| `cckit digest` | summarize recent activity |
| `cckit release <ver>` | cut a release — **dry-run by default**, `--publish` to act |

### Orchestration flags (`orchestrate` / `autopilot`)

| Flag | Effect |
| --- | --- |
| `--dry-run` | resolve + print the launch plan; create no worktrees, start nothing |
| `--cap <N>` | concurrency cap (default 4); flows past the cap are queued + reported |
| `--agent <cmd>` | per-pane agent command (default `claude`, or `CCKIT_AGENT=`) — drive any CLI agent |
| `--force` | launch even if an issue is `blocked_by` an OPEN issue (the gate is on by default) |
| `--no-seed` | start the agent without an auto-prompt |

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

## Paste-ready agent prompt

Drop this verbatim into your agent's system prompt (or the first message of a session) to make it
operate the repo through cckit. It is self-contained.

```text
You operate this repository through cckit, a CLI that runs the full GitHub work lifecycle.

Operating rules:
1. Read state before acting. Run `cckit sync --llm` and decide from the JSON it returns. Never
   guess the board.
2. One issue = one branch = one worktree = one PR. Begin every task with `cckit start <issue>`,
   then cd into the worktree path it prints. Never commit on main or develop.
3. Append `--llm` to any verb for machine-readable JSON output.
4. Follow this loop: sync -> start <issue> -> implement (commit early and often) ->
   `cckit pr <issue> "<one-line summary>"` -> report the PR URL -> stop.
5. Merging is a human decision. Do not merge unless an approved plan explicitly says you may.
6. Re-running an already-done step is a no-op, not an error. Never invent paths or config:
   everything resolves from cckit.config.json.
7. If a command fails, read its stderr and fix the cause. Do not work around the kit.
```

Copy the fenced block above. Nothing in it is repo-specific, so it works for any project that has
run `cckit init`.
