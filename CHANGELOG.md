# Changelog

All notable changes to cckit are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/), and releases are cut automatically from
[Conventional Commits](https://www.conventionalcommits.org/) on merge to `main`.

## [Unreleased]

### Fixed
- The `/kit-effort-close` skill is now a **thin caller** of `effort_close` — the exact function
  `cckit effort close` runs — so exactly ONE close implementation exists (the #121
  single-implementation precedent, applied to the close). The two skill-only steps moved into the
  verb: `effort_close` now sets the board **Status=Done** for the parent + every sub (guarded — a
  no-op when Projects v2 is off or the board helpers aren't captured) and finishes with the
  advisory **kit-sync drift check** flagging kit-managed files the effort touched (computed from
  the pre-squash branch diff, so it survives the close's own branch GC). Previously the skill and
  the verb each ran a divergent subset — the skill never captured the trace/telemetry and the verb
  never updated the board (#148).
- `init.sh --upgrade` (the `/kit-update` engine) now preserves existing project files it cannot
  prove it owns intact: the statusline wire step no longer replaces a customized (or
  manifest-untracked) `.claude/statusline.sh` shim with the template — the conffiles guard in
  `kit-operate` refuses to auto-overwrite an edited/unowned file even under `KIT_ASSUME_YES`,
  mirroring `kit_op_remove`. The `kit.config.json` upgrade merge is additive only for keys the
  template requires: feature blocks a project's config deliberately lacks (`plans`, `specKit`,
  `prePush`, `local`, `memory`) are never injected from profile defaults, and a config with no
  `plans` key no longer resurrects the profile's plan format (or its rules) on upgrade (#149).
- `cckit status` board counters no longer break. Status fed `task-sync --llm` output (TOON, not
  JSON) into `jq 'length'`, so the leading `[N]` header mis-parsed and the `|| echo 0` fallback
  concatenated onto jq's partial output (e.g. `1\n0`), throwing `integer expression expected` at
  the `[ "$open" -gt 8 ]` test and reporting a wrong count. It now fetches the board as a clean JSON
  array and guards each counter to an integer (#142).
- The foreign-repo acceptance harness (`scripts/portable-test.sh`) now enforces invoking-project
  resolution **by construction**: it iterates `cckit commands`, exercises every read-only verb
  against a foreign fixture (distinct repo, non-default base branch, org-owned board) with a stubbed
  gh, asserts no verb ever resolves cckit's own repo, and fails if any new verb is left unclassified
  — so coverage can't silently rot (#74).
- `cckit init` and the annotate setup now derive the project name / slug / wing from the git remote
  (the actual `owner/repo`) before falling back to the local directory basename — the directory is
  often cloned or renamed to something other than the repo name. Host-agnostic parsing (ssh, https,
  GHE/GitLab) lives in the shared `git-remote.sh` (#73).
- Project-config discovery is now a single shared resolver (`config-path.sh`): an explicit
  `KIT_CONFIG` always wins, else it walks up for a root `cckit.config.json` or a
  `.claude/kit.config.json`. `kit-doctor`, `kit-local`, `cckit update`, `cckit scan`, and
  `knowledge-lint` all discover config the same way instead of re-deriving it inline — so a
  root-config or an explicit `KIT_CONFIG` is honored everywhere, not just by the dispatcher (#69).
- Ported a batch of host-project lib fixes (#124): `cckit gc` classifies branches from a single
  `gh pr list` call indexed locally (no per-branch N+1) and iterates branches with `while read` so it
  survives a NUL-polluted `IFS`; effort token actuals attribute by branch **union** the effort's
  build time-window (recovering sessions the branch field alone missed); the `project_issue_status`
  board helper is restored and wired into a `cckit start` claim precheck (warns when an issue is
  already In Progress); and `cckit update` resolves the running install's version from the script's
  own directory (the old glob only matched `claude-kit*` and never a cckit install, so it silently
  no-op'd).
- `cckit watch --merge` now enforces auto-merge policy floors (default on): the captain never
  auto-merges a PR touching `.github/workflows/**`, lockfile/graph files (`pnpm-lock.yaml`,
  `package.json`, `*-workspace.yaml`, `turbo.json`, …), or security-sensitive paths (`*.pem`,
  `*.key`, `.env*`, secret paths), and always holds a `hold`-labelled or draft PR — surfacing them
  for human review instead. Configurable via `captain.mergePolicy` (`floors`, `protectedGlobs`) or
  `KIT_CAPTAIN_FLOORS` / `KIT_CAPTAIN_EXTRA_GLOBS` (#123).
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
