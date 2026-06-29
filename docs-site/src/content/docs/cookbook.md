---
title: Cookbook
description: Task-oriented recipes for the cckit lifecycle — ship an issue, run an effort, fan out flows in parallel, drive it unattended, and adopt an existing repo.
---

Recipes for the everyday jobs. Each one is a short sequence of real verbs — no org or repo is
hardcoded; everything reads from `cckit.config.json`. Append `--llm` to any verb for machine-readable
output (see [CLI reference](/cli-reference/)).

## Ship one issue end-to-end

The core lifecycle: isolated worktree → PR → close → clean up. Each step is a single command,
correct by construction.

```bash
cckit start 42                    # worktree + branch for issue #42, board → In Progress
# … make your changes in the new worktree …
cckit pr 42 "fix the thing"       # commit, push, open the PR, board → In Review
cckit close 42 "fix the thing"    # close the issue, board → Done
cckit gc --prune --yes            # remove the merged branch + worktree
```

`cckit sync` at any point shows the board state and what's unblocked.

## Plan and run a multi-part effort

An **effort** is a parent issue plus native sub-issues — use it when one unit of work decomposes
into several tasks. The parent issue *is* the plan.

```bash
cckit effort new "Auth rework"    # parent issue + sub-issues, all on the board
cckit effort start <N>            # integration branch effort/<N> + worktree
cckit effort plan                 # the session-fit work plan (add --llm for data)
# … build the sub-issues on the effort branch (sequential or in worktrees) …
cckit effort pr <N>               # one PR: effort/<N> → base branch
cckit effort close <N>            # squash-merge, close parent + all subs, garbage-collect
```

One effort = one PR. Sequential subs commit on the effort branch; file-disjoint subs run in their
own worktrees and merge in.

## Fan out N flows in parallel

`orchestrate` launches one isolated worktree per issue and runs them concurrently. Always
**dry-run first** to see the launch plan before anything is created.

```bash
cckit orchestrate --dry-run 6 7 8        # resolve + print the plan; create nothing
cckit orchestrate 6 7 8                  # launch all three (default cap: 4 concurrent)
cckit orchestrate --cap 3 6 7 8 9        # at most 3 at once; the rest queue and are reported
cckit orchestrate --agent codex 2 3      # drive each flow with a different agent command
```

The concurrency cap protects your machine; queued flows are reported, never silently dropped.

## Run it unattended (autopilot)

`autopilot` is a thin wrapper over `orchestrate`: hand it issues, or let it auto-pick what's
unblocked from the board, and it drives them under a cap until done.

```bash
cckit autopilot                    # auto-pick unblocked issues and drive them
cckit autopilot 12 13 14           # drive a specific set
cckit autopilot --cap 3            # bound concurrency (passed through to orchestrate)
```

Use this for overnight or hands-off runs with a verifiable stop condition.

## Adopt an existing repo

Bring cckit to a project that already has its own structure — nothing above the kit is
restructured.

```bash
cckit scan          # detect the repo's stack + current kit state (JSON)
cckit init          # scaffold cckit.config.json + .claude/ for this repo
cckit adopt         # record kit-shaped files the repo already has into the manifest
```

## Hand off and resume across sessions

cckit remembers where you left off, so the next session (or agent) picks up with full context.

```bash
cckit handoff "rebasing the auth branch, tests still red"   # save a resume-here note
cckit                                                       # bare verb: print the last handoff
```

## Keep the workspace clean

```bash
cckit gc                 # report-only: merged branches + orphan worktrees + stale stashes
cckit gc --prune         # prune them (asks before destructive steps)
cckit gc --prune --yes   # prune non-interactively
```

## Drive everything from an agent

Every verb has a structured mode so an agent reasons over data instead of scraping human output.

```bash
cckit sync --llm           # board state + what's unblocked, as JSON
cckit effort plan --llm    # the session-fit work plan, as data
cckit scan --llm           # repo stack + kit state, as JSON
cckit version --llm        # {"version":"0.1.3"}
```

See [Driving cckit from agents](/agents/) for the full agent contract.
