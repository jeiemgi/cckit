# Changelog

All notable changes to cckit are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/), and releases are cut automatically from
[Conventional Commits](https://www.conventionalcommits.org/) on merge to `main`.

## [Unreleased]

### Fixed
- Integration branch now resolves through a fallback chain — `github.baseBranch` →
  `github.integrationBranch` → `github.flow` → `main` — so a host project that names its
  integration branch under an alternate key resolves correctly on adoption instead of silently
  defaulting to `main`. Doctor's base-branch mismatch check uses the same chain (#117).
- Adoption hardening (#115): sourcing kit libs from an interactive zsh no longer breaks. The
  config accessor is namespaced (`_kit_cfg_get`, never a bare `g` that collides with `alias g=git`),
  and worktree/gc/events locals no longer shadow zsh's PATH-tied `path` array (#116). A new
  `zsh-safety-test.sh` asserts every affected lib sources and runs clean under `zsh -ic`.

### Added
- Initial standalone scaffold of cckit, extracted from the in-tree claude-kit (ADR-014).
- Agnostic secret + privacy guard (secret-guard.sh) wired into the gate and a pre-commit hook —
  blocks secrets, keys, env files (incl. .env.example), and user-declared private terms across all
  publishable content. See SECURITY.md.
  CLI dispatcher (`bin/cckit`), the git-mechanics bundle (`scripts/lib`), the Claude Code
  plugin, profiles, templates, the `AGENTS.md` agent contract, and the local gate
  (`scripts/check.sh`). Dual-licensed MIT OR Apache-2.0.
