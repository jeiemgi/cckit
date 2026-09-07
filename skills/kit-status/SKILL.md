---
name: kit-status
description: Answer "where are we?" in three buckets — local undone work (dirty worktrees, commits on no remote, effort subs not merged in), open PRs waiting on a human (no approval, no AI-reviewer pass, unresolved threads, red checks, conflicts), and cleanup available local + remote. Read-only.
when_to_use: When the owner asks where things stand — "where are we", "what's the state", "what's left", "what needs my attention", "anything to clean up" — or at the start of a session to pick up where the last one stopped. Read-only, so it is always safe to run first. For the board alone use `/kit-task-sync`; to act on the cleanup it reports use `/kit-cleanup`.
---

# kit-status — where are we?

Plugin-direct skill — a thin caller over `cckit status`. The bucket logic lives in
`${CLAUDE_PLUGIN_ROOT}/scripts/lib/kit-status.sh` (kit-engine-boundary: the verb logic has one
home, never inline in a skill).

**Run this before answering any "where are we" question with `git` output.** Plain `git status` and
`git branch -vv` answer a different question — they describe refs, not work — and they cannot see
which PRs are waiting on a person or which branches are safe to delete. That substitution is the
mistake this skill exists to prevent.

## Execution

```bash
cckit status          # the three buckets as markdown
cckit status --llm    # the same verdicts as JSON, for an agent
```

Read-only. It writes nothing, deletes nothing, and pushes nothing.

## The three buckets, in this order

| # | Bucket | What it answers |
| --- | --- | --- |
| 1 | **Local undone work** | What exists only on this machine: worktrees with uncommitted changes, branches holding commits reachable from **no** remote ref, and effort subs not yet merged into their effort branch. Plus the worktree inventory — a clean worktree on an issue branch is still work in progress. |
| 2 | **PRs waiting on a human** | Every open PR with the ONE thing it needs: `conflict`, `checks`, `draft`, `wait`, `threads`, `ai-review`, `review`, or `ready`. |
| 3 | **Cleanup available** | Branches and worktrees that can go — **local and remote** — plus what is deliberately kept (orphan work, open-issue branches). |

## Reading bucket 2

The verdict is the single next action, most-blocking first, because the later signals cannot be
acted on until the earlier ones clear:

| Verdict | Means |
| --- | --- |
| `conflict` | Merge state is `CONFLICTING`. Rebase onto the base; nothing else about the PR can be judged until then. |
| `checks` | A required check is failing. A review would be premature. |
| `draft` | Still a draft — the author has not asked for anything yet. |
| `wait` | Checks are still running. Nothing to do but wait. |
| `threads` | Unresolved review threads. The reviewer already spoke, so this outranks a missing approval. |
| `ai-review` | No AI-reviewer pass yet. Only reported when the repo evidently uses one (a reviewer config, or an AI review on another open PR) — never in a repo that has none. |
| `review` | Green, no human approval yet. This is the one that needs the owner. |
| `ready` | Green and approved. Mergeable. |

**A superseded check run never counts.** Re-running a check — or retitling a PR, which re-fires a
title gate — leaves the old run in GitHub's rollup. Counting every context there reports a PR as
failing a check that has since passed, so the fetcher keeps only the latest run per check name.

## Rules

- **Never answer a "where are we" question from `git` output alone.** Run this first; drop to raw
  `git` or `gh` only for something the buckets genuinely do not cover, and say what that was.
- **Present all three buckets, in order, even when one is empty.** Each bucket names its own
  emptiness ("nothing local-only", "no open PRs"). A silently missing bucket is indistinguishable
  from a clean one, and this report is read to decide what to do next.
- **Report, do not act.** This skill deletes nothing and merges nothing. Bucket 3 is a pointer to
  `/kit-cleanup`; bucket 2 is a pointer to a review or a merge. Ask before acting on either.
- **Do not restate the raw table.** Lead with what needs the owner's attention — usually the PRs
  with `review` or `threads` — then the rest.
