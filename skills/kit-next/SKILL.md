---
name: kit-next
description: >
  The everyday cckit loop: find the next unblocked issue and pick it up, or fan the whole unblocked
  wave out to subagents. Wraps `cckit next` (what can I work on now?), `cckit start <N>` (isolated
  worktree + branch), `cckit copilot` (parallel fan-out), and `cckit watch` (gate + merge PRs).
when_to_use: >
  When you sit down to work and want the next thing to do, when you finish an issue and need the
  next one, or when you want to parallelize the unblocked wave. Not for planning an effort
  (/kit-effort-new) or for a one-off task you already have in hand.
metadata:
  version: 1.0.0
---

# kit-next — the everyday loop

Answer one question fast: **what should I work on right now, and how do I start it?**

## Pick up the next issue

```
cckit next
```

Prints the unblocked set (wave 0 of the plan) and the single recommended next issue with its start
command. `--effort <N>` scopes it to one effort's sub-issues.

Then start the top one in its own worktree + branch:

```
cckit start <N>
```

Implement it, run `bash scripts/check.sh` until green, open the PR with `cckit pr <N> "<summary>"`
(or close a no-op with `cckit close <N> "<reason>"`), then run `cckit next` again.

## Or fan the whole wave out

When the unblocked issues are file-disjoint and independent, drive them in parallel instead of one
at a time:

```
cckit copilot          # emits a Task-subagent fan-out brief for wave 0
cckit watch --merge    # gate every open PR; squash-merge the CLEAN ones; advance the next wave
```

`cckit watch --loop` lets the captain self-pace the gate/merge passes until steady state.

## Surface it automatically (optional)

To see the next issue every time a session starts, add a `SessionStart` hook that runs
`cckit next` (or `cckit next --effort <N>`). Keep it opt-in — it prints on every new session, so
only wire it on repos where you want that nudge. See the Claude Code hooks docs for the
`SessionStart` event shape.
