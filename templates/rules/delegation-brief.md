# Delegation brief — what every delegated agent gets up front

When spawning a sub-agent (Agent tool, orchestrate, CI agent), **prepend this**. It encodes the
environment knowns so agents don't burn turns rediscovering "how do I get X". Keep it current —
when an agent rediscovers something it should have been handed, add it here.

## Project specifics (fill these in for {{PROJECT_NAME}})

- Repo `<owner>/<repo>` · base branch **`<base>`** · owner **`<owner>`** · project board number **`<N>`**.
- Build/dep tooling (e.g. pnpm + turbo monorepo, workspaces, package scope).
- **Secrets by NAME, never value** — the GitHub API token env var (some apps use a custom name like
  `GH_PAT`, **not** `GITHUB_TOKEN` — state which), model/API env vars, auth keys. Say which file/code
  path reads each.

## Standing gotchas (transferable — these bite on most projects)

- **Refresh the base first.** An isolation worktree can seed from a **stale commit**. Start with
  `git fetch origin <base> && git reset --hard origin/<base>` on a fresh branch; confirm
  `git rev-parse --short HEAD` == `origin/<base>`.
- **Commit so the guard sees the right branch.** A base-branch commit guard inspects the command's
  named directory — a `$VAR` path can resolve to the main checkout and false-block. Commit via
  `git -C <literal-worktree-path>` or `cd <literal-path>` (never a variable).
- **zsh quirks:** `${VAR:+--flag "$VAR"}` word-splits — pass flags explicitly. `status` and `path`
  are read-only vars — don't use them as loop variables.
- **Board finder paginates the full board.** `project_find_item_by_issue` (gh-project.sh) pages the
  whole board — use it; don't hand-roll a `first:100` query that misses recent issues.
- **Never hard-code the config path.** Two layouts exist and both are current, so
  `.claude/kit.config.json` is a guess, not the answer. `kit_config_path` (`scripts/lib/config-path.sh`)
  resolves it in this order, walking up from the start dir: `$KIT_CONFIG` if set → a root
  `cckit.config.json` (self-host layout) → `.claude/kit.config.json` (scaffolded layout). Read
  `.github.owner` / `.github.projectNumber` / `.github.baseBranch` out of whatever it prints, or let
  `load_kit_config` (`scripts/lib/kit-config.sh`) export `KIT_REPO` / `KIT_OWNER` /
  `KIT_BASE_BRANCH` / `KIT_PROJECT_NUMBER` for you.
- **Project IDs are worktree-durable.** `source scripts/lib/gh-project.sh; load_project_ids` reads
  the captured IDs from the shared git-common-dir, so worktrees see them too.

## Durable prose — the concrete pass

Any delegated agent that will write a **durable artifact** — a GitHub issue body, a PR body, a
commit message, a rule, an ADR, a knowledge doc — applies the `concrete` catalogue to that text
**before** writing it.

The brief has to say this, because a sub-agent applies a skill only when it is told to or can read
the skill file. An installed skill that no brief mentions does not fire. That is what happened in
this kit: `concrete` shipped in PR 247, `communication-style.md` has mandated the pass for durable
prose ever since — and no brief mentioned it, so no issue or PR body records one (issue #254 exists
to run the kit's own prose through it after the fact).

The constraints, so this block is self-sufficient when the skill file is not in the agent's context:

- **Cut only by NAMED offense, never by length.** A text can be long and clean. Name the offense in
  the diagnosis so the author can argue with it.
- **Untouchable:** evidence, command output, exit codes, reproductions, counts, dates, SHAs,
  `file:line`, flag and label names, stated limits, and the reason a claim was rejected. If a cut
  would remove one of these, the text is dense, not slop.
- **`O13` unverifiable claim** ("this improves quality", "this is more secure") and **`O14`
  undecided decision** (options listed as though a conclusion) are the two that matter. When either
  fires, the fix is the underlying gap — verify the claim, or make the decision. Rewording it into
  fluent prose is the failure mode, not the fix.

`communication-style.md` states the mandate; this block is what carries it into a delegated agent's
context.

## Gate commands (fill in for {{PROJECT_NAME}})

- Build / typecheck / lint commands; shell scripts: `bash -n`; any knowledge/plan lint. A green
  build/typecheck is the bar. State whether CI exists or the gate is local + deploy-provider build.

## Effort flow (the unit of work)

- 1 effort = parent issue + native sub-issues + `effort/<N>` branch + **1 PR** (+ a `## For agents`
  section listing touched files). See `effort-model.md`. Sub-agents **don't merge** — implement,
  push, open the PR, and report the PR URL + a short summary + risks.
