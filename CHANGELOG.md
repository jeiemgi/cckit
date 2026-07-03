# Changelog

All notable changes to cckit are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/), and releases are cut automatically from
[Conventional Commits](https://www.conventionalcommits.org/) on merge to `main`.

## [Unreleased]

### Fixed
- `cckit gc` now honors recover-before-prune. A zombie worktree (its working dir gone but its admin
  metadata lingering) can hold staged-but-uncommitted work in its admin index — the only blob→path
  map — which `git worktree prune` would orphan. gc now detects zombies (and staged-without-commit)
  as their own analysis bucket, recovers any staged delta to its branch as a commit via
  `write-tree`/`commit-tree`/`update-ref` before pruning, and no longer runs `git worktree prune`
  in a dry-run (#111).
- Effort PRs are now titled by ONE shared composer used by both `cckit effort pr` and the
  kit-effort-pr skill, so a PR is titled identically no matter who opens it — and both refuse to
  open a PR whose title lacks the mandatory `[#N]` effort id. `cckit effort new` gained a `--par`
  option (`seq` | `wide` | `<int>` → a `par:` label) and now parses flags in ANY position: a
  `--flow`/`--role` placed after the title is honored instead of being mis-read as a sub-issue spec
  (which previously created junk sub-issues) (#121).
- `cckit effort close` now runs the whole close in one op: it captures effort metrics before the
  squash and judges + syncs them after, refuses to squash-merge when no per-sub work trace was
  captured (the squash is irreversible; override with `KIT_FORCE=1`), garbage-collects the effort
  worktree/branch, and runs an optional config-gated knowledge-ingest hook
  (`effort.knowledgeIngestHook`, a no-op when absent). The pre-squash sub-diff snapshot is unchanged (#120).
- `cckit effort start` now gives its worktree the full `cckit start` setup — gitignored env-file
  copy, per-worktree dev port, and dependency install (opt out with `KIT_WT_INSTALL=0`) — plus a
  live-session collision guard. Its worktree dir now follows the `effort+<N>-<slug>` convention
  (matching the skill) so kit-gc's issue-open protection recognizes it by directory name (#119).
- Projects v2 board capture now honors `github.projectOwnerType` (`user` | `organization`, default
  `user`). An organization-owned board previously returned null from the user-only GraphQL root, so
  field/option IDs never captured; `capture-project-ids.sh` now selects `organization(login:)` vs
  `user(login:)` to match, and `kit-config` exports `KIT_PROJECT_OWNER_TYPE` (#118).
- Integration branch now resolves through a fallback chain — `github.baseBranch` →
  `github.integrationBranch` → `github.flow` → `main` — so a host project that names its
  integration branch under an alternate key resolves correctly on adoption instead of silently
  defaulting to `main`. Doctor's base-branch mismatch check uses the same chain (#117).
- Adoption hardening (#115): sourcing kit libs from an interactive zsh no longer breaks. The
  config accessor is namespaced (`_kit_cfg_get`, never a bare `g` that collides with `alias g=git`),
  and worktree/gc/events locals no longer shadow zsh's PATH-tied `path` array (#116). A new
  `zsh-safety-test.sh` asserts every affected lib sources and runs clean under `zsh -ic`.

### Added
- `cckit sync` now renders a fuller board view: each issue row shows its **Project Status** (from
  the Projects v2 board when enabled), a **Merge Queue** of open PRs ordered for top-down merging
  (ready → draft → blocked; within a tier risk:low first, then smaller size, then number, with a
  bot-branch flag), and **blocked / not-on-board / stale (>14d)** flags. An optional local-model
  digest is appended only when the local endpoint is alive. Render logic lives in the unit-tested
  `board-view.sh` (#122).
- Initial standalone scaffold of cckit, extracted from the in-tree claude-kit (ADR-014).
- Agnostic secret + privacy guard (secret-guard.sh) wired into the gate and a pre-commit hook —
  blocks secrets, keys, env files (incl. .env.example), and user-declared private terms across all
  publishable content. See SECURITY.md.
  CLI dispatcher (`bin/cckit`), the git-mechanics bundle (`scripts/lib`), the Claude Code
  plugin, profiles, templates, the `AGENTS.md` agent contract, and the local gate
  (`scripts/check.sh`). Dual-licensed MIT OR Apache-2.0.
