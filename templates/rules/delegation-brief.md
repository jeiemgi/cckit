# Delegation brief — what every delegated agent gets up front

When spawning a sub-agent (Agent tool, orchestrate, CI agent), **prepend this**. It encodes the
environment knowns so agents don't burn turns rediscovering "how do I get X". Keep it current —
when an agent rediscovers something it should have been handed, add it here.

## Project specifics (fill these in for {{PROJECT_NAME}})

- Repo `<owner>/<repo>` · base branch **`main`** · owner **`<owner>`** · project board number **`<N>`**.
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
  whole board — use it; don't hand-roll a `first:100` query that misses recent issues. Owner/project
  number resolve from `.claude/kit.config.json` (`.github.owner`, `.github.projectNumber`).
- **Project IDs are worktree-durable.** `source scripts/lib/gh-project.sh; load_project_ids` reads
  the captured IDs from the shared git-common-dir, so worktrees see them too.

## Gate commands (fill in for {{PROJECT_NAME}})

- Build / typecheck / lint commands; shell scripts: `bash -n`; any knowledge/plan lint. A green
  build/typecheck is the bar. State whether CI exists or the gate is local + deploy-provider build.

## Effort flow (the unit of work)

- 1 effort = parent issue + native sub-issues + `effort/<N>` branch + **1 PR** (+ a `## For agents`
  section listing touched files). See `effort-model.md`. Sub-agents **don't merge** — implement,
  push, open the PR, and report the PR URL + a short summary + risks.
