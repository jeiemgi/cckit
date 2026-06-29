# Config, scanning, and the permission gate (spike #1091)

How cckit discovers its config, scans a project, asks permission before it mutates anything, and
identifies the user — all project-agnostic.

## Config resolution (nearest wins)

cckit reads one config, resolved in this order (first hit wins):

1. `$KIT_CONFIG` (explicit override)
2. `cckit.config.json` at the repo root
3. an ancestor `.cckit/config.json` (per-folder override, like `.editorconfig`)

No org, repo, or path is hardcoded — every value (owner, repo, base branch, board) comes from this
file. A repo with no config is invited to run `cckit init`.

## Project scanning

`cckit` detects the project it is pointed at from the filesystem, not from baked-in knowledge:

- **repo root** — `git rev-parse --show-toplevel`.
- **stack hints** — `package.json` / `pyproject.toml` / `go.mod` / `Cargo.toml` presence.
- **kit state** — `cckit.config.json`, `.claude/`, `.cckit/`.

`scripts/lib/project-scan.sh` exposes this as `project_scan` → a small JSON summary an agent can read.

## The permission gate (ask before operating)

cckit is agent-operable and may run unattended, so a mutation gate is mandatory:

- **Read-only by default in an unknown repo.** Before the first *mutating* op (branch, commit, push,
  issue write) in a repo cckit has not operated in before, it records consent in `.cckit/consent`
  (gitignored). A human (or an explicitly-authorized autopilot scope) grants it once.
- **The secret/privacy guard always runs** before anything is committed or published
  ([SECURITY.md](../SECURITY.md)) — it is not optional and not bypassed by consent.
- **Destructive/irreversible ops** (force-push, repo create, history rewrite) are never auto-granted
  by consent; they require an explicit, separate confirmation.

## Identity (agnostic)

cckit asks the user their name on first run and stores it in `.cckit/identity` (gitignored). Nothing
personal is hardcoded anywhere in the repo — commits/attribution use the local git identity, and the
published artifacts carry only generic, invented examples (`OWNER/REPO`, `acme`).
