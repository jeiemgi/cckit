---
name: kit-status
description: Answer "where are we?" in three buckets — local undone work (dirty worktrees, commits on no remote, effort subs not merged in), open PRs waiting on a human (no approval, no AI-reviewer pass, unresolved threads, red checks, conflicts), and cleanup available local + remote. Read-only, so it is always safe to run first.
when_to_use: |
  Whenever the owner asks, in ANY wording, how things stand overall — this is the default answer to
  an open status question, and it fires on the phrasing people actually use, not one canonical form:

  - "where are we" · "where we at" · "where are we at" · "where do we stand" · "where did we leave off"
  - "status" · "what's the status" · "give me a status" · "sitrep" · "state of play"
  - "what's the current state" · "current state" · "what's the state of things"
  - "how are we doing" · "how's it going" · "how are things" · "how're we looking" · "are we good"
  - "what's left" · "what's outstanding" · "what's still open" · "anything pending"
  - "what needs my attention" · "anything waiting on me" · "anything I need to look at"
  - "anything to clean up" · "is the repo tidy"
  - "catch me up" · "recap" · "bring me up to speed" · "what did we do" · "update me"
  - at the start of a session, to pick up where the last one stopped
  - the same question in whatever language the project speaks (`project.language` in the config) —
    in Spanish: "cómo vamos" · "en qué estamos" · "qué falta" · "estado" · "dónde quedamos"

  The list is illustrative, not exhaustive. Any open-ended question about overall progress belongs
  here, including phrasings not written above.

  SKIP it when the question has a specific subject — "how's the login bug doing", "what's the status
  of PR 41", "where are we on the migration". Those are about one thing; answer them directly. This
  skill is for the unqualified question, where the owner wants the whole picture.

  For the board alone use `/kit-task-sync`; for what to pick up next use `/kit-next`; to act on the
  cleanup this reports use `/kit-cleanup`.
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

- **Never answer a status question from `git` output alone.** Run this first; drop to raw `git` or
  `gh` only for something the buckets genuinely do not cover, and say what that was.
- **Match on intent, not on wording.** "how are we doing", "catch me up", "cómo vamos" and "where
  we at" are the same question. Do not wait for the phrase "where are we" — an unqualified question
  about overall progress is this skill, whatever words or language it arrives in.
- **Present all three buckets, in order, even when one is empty.** Each bucket names its own
  emptiness ("nothing local-only", "no open PRs"). A silently missing bucket is indistinguishable
  from a clean one, and this report is read to decide what to do next.
- **Report, do not act.** This skill deletes nothing and merges nothing. Bucket 3 is a pointer to
  `/kit-cleanup`; bucket 2 is a pointer to a review or a merge. Ask before acting on either.
- **Do not restate the raw table.** Lead with what needs the owner's attention — usually the PRs
  with `review` or `threads` — then the rest.
