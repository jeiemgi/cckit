---
title: Cookbook
description: An AI-agent playbook for cckit — the correct flow for each job, how to configure it, and copy-paste prompts you hand to Claude Code or any coding agent.
---

This cookbook is written for **AI agents** (Claude Code and any coding agent) driving cckit — and
for the humans steering them. Each recipe gives you three things:

1. **The prompt** — copy-paste text you hand the agent. This is the main artifact; in most cases you
   prompt, you don't type commands yourself.
2. **The flow** — the correct order of operations the agent follows, so it doesn't skip a step or
   invent one.
3. **Configure** — any one-time setup the recipe assumes.

cckit is built to be agent-operable: every verb has a machine-readable mode (`cckit <verb> --llm`)
and the repo ships an [`AGENTS.md`](/agents/) contract, so an agent reasons over structured data
instead of scraping human output. Point your agent at `AGENTS.md` once and it knows the grammar.

## How an agent drives cckit

The pattern every recipe below builds on:

- The agent **reads state as data**: `cckit sync --llm`, `cckit scan --llm`, `cckit status`.
- It **acts through verbs**, one lifecycle step per command (`start` → `pr` → `close`).
- It **never hardcodes** an org or repo — everything resolves from `cckit.config.json`.

> **Prime your agent once (copy-paste):**
> ```text
> Read AGENTS.md and cckit.config.json in this repo. From now on, use the cckit CLI for the
> work lifecycle: `cckit sync --llm` to see the board, `cckit start <issue>` to begin work in an
> isolated worktree, `cckit pr <issue> "<summary>"` to open the PR, and `cckit close <issue>
> "<summary>"` to finish. Always read state with `--llm` and reason over the JSON.
> ```

## Configure cckit in a repo (one-time)

**Configure.** cckit needs `git`, `gh` (authenticated), and `jq`. It reads everything from
`cckit.config.json`, which `init` scaffolds.

> **Prompt:**
> ```text
> Set up cckit in this repository. Run `cckit init` to scaffold cckit.config.json and the .claude/
> setup, confirm gh is authenticated with `cckit doctor`, then show me `cckit scan --llm` so I can
> verify it detected the stack and repo correctly.
> ```

**Flow:**
```bash
cckit init        # scaffold cckit.config.json + .claude/
cckit doctor      # preflight: deps + gh auth
cckit scan --llm  # verify detected stack + kit state (JSON)
```

## Ship one issue end-to-end

The core lifecycle: isolated worktree → PR → close → clean up. Each step is one verb, correct by
construction — the agent should run them in this order and not improvise branch/PR plumbing.

> **Prompt:**
> ```text
> Take issue #42 from start to merged using cckit. First `cckit start 42` to get an isolated
> worktree and branch. Make the change there, keeping the diff focused on the issue. Then
> `cckit pr 42 "<one-line summary>"` to commit, push, and open the PR. After it merges,
> `cckit close 42 "<summary>"` and `cckit gc --prune --yes` to clean up. Report the PR URL.
> ```

**Flow:**
```bash
cckit start 42                 # worktree + branch for #42, board → In Progress
# …agent makes the change in the new worktree…
cckit pr 42 "fix the thing"    # commit, push, open the PR, board → In Review
cckit close 42 "fix the thing" # close the issue, board → Done
cckit gc --prune --yes         # remove the merged branch + worktree
```

`cckit sync --llm` at any point gives the agent the board state and what's unblocked.

## Plan and run a multi-part effort

An **effort** is a parent issue plus native sub-issues — use it when one goal decomposes into
several tasks. The parent issue *is* the plan, so the agent reads it instead of a separate doc.

> **Prompt:**
> ```text
> This work is too big for one PR — turn it into a cckit effort. Create the effort with
> `cckit effort new "<name>"`, decomposed into sub-issues for each independent piece. Then
> `cckit effort start <N>` for the integration branch, build each sub-issue (use separate
> worktrees for file-disjoint ones), and when all subs are merged into the effort branch open the
> single PR with `cckit effort pr <N>`. Read `cckit effort plan --llm` to size the work first.
> ```

**Flow:**
```bash
cckit effort plan --llm        # session-fit plan over open efforts (data)
cckit effort new "Auth rework" # parent issue + native sub-issues, all on the board
cckit effort start <N>         # integration branch effort/<N> + worktree
# …build sub-issues on the effort branch (sequential) or in worktrees (parallel)…
cckit effort pr <N>            # ONE PR: effort/<N> → base branch
cckit effort close <N>         # squash-merge, close parent + all subs, garbage-collect
```

## Fan out flows in parallel / run unattended

For several independent issues at once, the agent orchestrates parallel worktrees — **always
dry-run first** so it (and you) can see the launch plan before anything is created.

> **Prompt (parallel):**
> ```text
> Drive issues 46, 47, and 48 in parallel with cckit. Start with
> `cckit orchestrate --dry-run 46 47 48` and show me the plan. If it looks right, launch them with
> a concurrency cap of 3 (`cckit orchestrate --cap 3 46 47 48`), then summarize each flow's result.
> ```

> **Prompt (unattended / overnight):**
> ```text
> Run cckit autopilot to clear the unblocked backlog: `cckit autopilot --cap 3`. Let it auto-pick
> unblocked issues from the board and drive them under the cap. Stop and ping me only on a genuine
> blocker; otherwise give me a summary of what merged when it's done.
> ```

**Flow:**
```bash
cckit orchestrate --dry-run 46 47 48  # resolve + print the plan; create nothing
cckit orchestrate --cap 3 46 47 48    # launch, at most 3 concurrent; the rest queue
cckit autopilot --cap 3               # auto-pick unblocked issues and drive them
```

## Adopt an existing repo

Bring cckit to a project that already has its own structure — nothing above the kit is restructured.

> **Prompt:**
> ```text
> Adopt cckit into this existing project without disrupting its layout. Run `cckit scan` to see the
> current state, `cckit init` to add the config, and `cckit adopt` to record the kit-shaped files
> the repo already has. Then confirm with `cckit status`.
> ```

**Flow:**
```bash
cckit scan      # detect the repo's stack + current kit state
cckit init      # scaffold cckit.config.json + .claude/
cckit adopt     # record kit-shaped files the repo already has
cckit status    # confirm the board + worktrees + handoff view
```

## Drive cckit as pure data (headless agents)

For a non-interactive agent (CI bot, scheduled run), skip human output entirely and consume JSON.
Every verb that reports state takes `--llm`.

> **Prompt:**
> ```text
> You are running headless. Use only the --llm forms: get the board with `cckit sync --llm`, pick
> the highest-priority unblocked issue, and drive it through `cckit start` / `cckit pr` /
> `cckit close`. Encode any uniform-array context you pass to a sub-agent with `cckit encode-context`
> (TOON) to save tokens.
> ```

**Flow:**
```bash
cckit sync --llm          # board state + what's unblocked, as JSON
cckit scan --llm          # repo stack + kit state, as JSON
cckit effort plan --llm   # the session-fit work plan, as data
echo "$json" | cckit encode-context   # compact uniform arrays into TOON for sub-agents
```

See [Driving cckit from agents](/agents/) for the full machine contract, and the
[Showcase](/showcase/) for what each command's output actually looks like.
