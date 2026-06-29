---
name: kit-dev
description: >
  Fast local dev loop for claude-kit itself (the plugin source). start: worktree +
  launch instructions for `claude --plugin-dir` (plugin loads live from disk, no cache, no
  version bump). Iterate with /reload-plugins. ship: auto-bump semver + kit-task-pr-auto +
  one-command update of the installed plugin.
when_to_use: >
  When modifying the kit itself — skills, agents, hooks, scripts, profiles in the
  claude-kit-plugin source — and you want to test changes live without the
  merge→bump→marketplace-update cycle. Not for consuming the kit (that's /kit-update).
---

# kit-dev — develop claude-kit without the publish cycle

The kit's source of truth is the `claude-kit-plugin` package; the installed plugin comes from
the marketplace (dedupes by version). This skill replaces the slow loop (merge → manual bump →
marketplace update → plugin update) with a live local loop.

## Subcommands

`/kit-dev start <issue>` · `/kit-dev ship` · bare `/kit-dev` = print the loop + current state.

## start — open the loop

1. Worktree first, like all repo work: run the `/kit-task-start <N> --worktree` flow
   (branch `task/<N>-<slug>` from the base branch). All kit edits happen in the worktree.
2. Launch the dev session **from the worktree** with the plugin loaded live:

```bash
cd .claude/worktrees/<kind>+<N>-<slug>
claude --plugin-dir "$PWD/packages/claude-kit-plugin"
```

- `--plugin-dir` loads the plugin directly from disk — no cache, no install, no version.
- The dev-session plugin shadows the marketplace install for that session; the rest of
  the sessions keep the stable installed kit.

## iterate — the inner loop

- Edit skills / agents / hooks / scripts in the plugin source.
- In the dev session run `/reload-plugins` — picks up the edits in-session (skills, agents,
  hooks, MCP). No restart needed; restart only if `/reload-plugins` misbehaves.
- Project-level kit files (`.claude/skills/`, `scripts/`, rules) are ordinary repo files —
  same worktree, no reload mechanics, new session reads them fresh.

## ship — land it and update the installed kit

1. `"${CLAUDE_PLUGIN_ROOT}/scripts/kit-bump-version.sh" beta` — bumps `version.json`,
   `plugin.json`, `package.json`, and the marketplace manifest(s) in sync.
   (`patch`/`minor`/explicit semver for releases — a clean release advances the `stable`
   channel, a `-beta.N` build advances `beta`.) NEVER ship a kit change without the bump:
   `/plugin update` dedupes by version and silently skips.
2. Run the `/kit-task-pr-auto` flow — commit, push, PR (`Closes #N`), squash-merge to the base.
3. Update the installed plugin (one command, in any session):

```
/plugin marketplace update claude-kit-marketplace
/plugin update claude-kit@claude-kit-marketplace
```

## Rules

- Worktree always — never edit the kit in the main checkout.
- The semver in `plugin.json`/`version.json` is load-bearing: the session banner and `/kit-update`'s
  changelog delta read it. Auto-bump on ship, never remove it.
- The lockfile rule still applies if a kit change touches deps.
