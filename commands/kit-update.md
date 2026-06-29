---
description: Bring a kit-scaffolded project up to the latest claude-kit — shows the changelog delta and merge-upgrades the project's .claude/ without clobbering your customizations.
argument-hint: "[--check] [--dry-run]"
allowed-tools: Bash, Read, AskUserQuestion, Edit
---

# /kit-update — update this project to the latest claude-kit

The kit lives at `${CLAUDE_PLUGIN_ROOT}`. This surfaces what changed since this project was last
scaffolded and **merges** new features in — preserving your edits. Re-running is safe.

## Steps

### 0. Pre-flight safety checks (run these before everything else — abort on failure)

**a) Dirty working tree guard.**

Run:
```bash
git -C "$PWD" status --porcelain 2>/dev/null
```

If there is any output (staged, unstaged, or untracked changes), **stop immediately** and
tell the user:

> "working tree is dirty -- commit, stash, or discard before running /kit-update"

Write nothing. Do not show the changelog. Do not proceed. The underlying `init.sh --upgrade`
enforces the same check, but surfacing it here avoids wasted steps. The check is a safe no-op
when `$PWD` is not a git repo (no git binary, detached context, etc.) — skip silently in that case.

**b) Plugin source staleness check.**

Detect whether the plugin source directory (`${CLAUDE_PLUGIN_ROOT}`) is behind its own
`origin` remote. This is best-effort — skip silently if git is unavailable, there is no remote,
or the network is unreachable.

```bash
# 1. Verify the source is inside a git repo.
git -C "${CLAUDE_PLUGIN_ROOT}" rev-parse --git-dir >/dev/null 2>&1 || echo "no-git"

# 2. Resolve the integration branch (prefer the remote HEAD, fall back to develop).
_branch="$(git -C "${CLAUDE_PLUGIN_ROOT}" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null \
           | sed 's|refs/remotes/origin/||')"
[ -z "$_branch" ] && _branch="develop"

# 3. Fetch quietly (failures are non-fatal — the check is best-effort).
git -C "${CLAUDE_PLUGIN_ROOT}" fetch origin "$_branch" --quiet 2>/dev/null || true

# 4. Count commits the source is behind.
_behind="$(git -C "${CLAUDE_PLUGIN_ROOT}" rev-list --count HEAD.."origin/$_branch" 2>/dev/null || echo 0)"
```

If `_behind` > 0:

- Print a prominent warning (ASCII only, no emoji):
  > "[warn] plugin source is $_behind commit(s) behind origin/$_branch -- you may be installing an older version of claude-kit"
  > "Update the source first:  git -C ${CLAUDE_PLUGIN_ROOT} pull  then re-run /kit-update."
- Use `AskUserQuestion` to ask:
  - **Abort** (recommended) — stop here so the user can update the plugin source
  - **Continue with stale source** — proceed anyway (risk: may downgrade the project)
- In non-interactive or CI contexts where `AskUserQuestion` is unavailable, **abort** and print
  the warning above.
- If the user chooses Abort or the context is non-interactive: stop, write nothing.
- If the user explicitly chooses to continue: proceed with a final reminder that files may
  be older than what is on origin.

If `_behind` is 0, or the git check cannot be completed for any reason, continue silently.

**c) Home-repo + downgrade guard.** `/kit-update` is for **consumer** projects (pull the kit into
my `.claude/`). It must never run in claude-kit's **own home repo** (where the kit is developed
in-tree) nor **downgrade**:

```bash
# Home repo? (the kit's source lives here — editing it via /kit-update is a category error)
[ -f "$PWD/packages/claude-kit-plugin/.claude-plugin/plugin.json" ] && echo "home-repo"
# Same version? (nothing to add)
_have="$(jq -r '.kitVersion // "0.0.0"' "$PWD/.claude/kit.config.json" 2>/dev/null)"
_plug="$(jq -r '.version // "0.0.0"' "/Users/josegutierrezdelgado/.claude/plugins/cache/claude-kit-marketplace/claude-kit/0.7.0-beta.6/.claude-plugin/plugin.json" 2>/dev/null)"
[ "$_have" = "$_plug" ] && echo "same-version"
```

- If `home-repo`: **stop.** Tell the user: *"this IS claude-kit's home repo — edit
  `packages/claude-kit-plugin/` directly and open a normal PR; `/kit-update` is for consumer
  projects."* Write nothing.
- If `same-version` (and not behind): **stop** — "already at $_plug, nothing to upgrade." To pull a
  newer release, refresh the plugin cache (`claude plugin update`), not `/kit-update`.
- `init.sh --upgrade` enforces both as a backstop, but surfacing them here avoids wasted steps.

1. **Check versions.** Run:
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/kit-version-check.sh" --target "$PWD" --plugin-root "${CLAUDE_PLUGIN_ROOT}"
   ```
   Compare the project's `.claude/kit.config.json` `.kitVersion` with the installed
   `${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json` `.version`. If equal, say "you're up to date" and
   stop — unless `--check`/`--dry-run` was passed, then continue to preview.

2. **Show the changelog delta — make it feel good, not behind.** Read
   `${CLAUDE_PLUGIN_ROOT}/CHANGELOG.md` and summarize, in plain language, the entries between the
   project's version and the installed version: the new commands/skills/rules/config, what each
   unlocks, and the exact command to try it (e.g. `/kit-annotate`). Lead with the value.

3. **Preview the upgrade (always).** Run:
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/init.sh" --upgrade --target "$PWD" --dry-run
   ```
   Then run it for real to see the precise added/preserved report (step 4). Make clear: upgrade only
   **adds** missing files and **merges** new config keys — your existing `.claude/` files and
   `kit.config.json` values are never overwritten.

4. **Confirm, then apply.** Ask with `AskUserQuestion`: **Apply update** · **Preview only** · **Skip**.
   Per the CLI-style preference, when the delta is purely additive (only new files, nothing preserved
   would conflict) you may offer to **apply automatically**. On apply:
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/init.sh" --upgrade --target "$PWD"
   ```

5. **Report + onboard.** Echo what was **added** vs **preserved** and the new `.kitVersion`. Then warmly
   walk the user through the headline new features and offer to run any that fit this project (e.g.
   "this release adds `/kit-annotate` — want me to set it up?"). The goal is comfort with the new
   surface, not a changelog dump.

## Rules

- **Never clobber.** Upgrade only ADDS missing files and MERGES new `kit.config.json` keys; existing
  files and config values are preserved. Always show the `--dry-run` preview before applying.
- When reporting effective configuration, honor per-folder `.claudekit/config.json` overrides
  (nearest-wins) — see `scripts/lib/kit-config.sh`.
- Don't fabricate changelog content — read `CHANGELOG.md`. If the project predates version tracking
  (`kitVersion` missing or `0.1.0`), treat everything in the changelog as new.
- **Messages use ASCII/sigil glyphs only** — no emoji characters. Use `x ` for errors, `[warn]` for
  warnings, `->` for actions.
