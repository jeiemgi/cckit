# Changelog

All notable changes to cckit are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/), and releases are cut automatically from
[Conventional Commits](https://www.conventionalcommits.org/) on merge to `main`.

## [Unreleased]

### Added
- Initial standalone scaffold of cckit, extracted from the in-tree claude-kit (ADR-014).
- Agnostic secret + privacy guard (secret-guard.sh) wired into the gate and a pre-commit hook —
  blocks secrets, keys, env files (incl. .env.example), and user-declared private terms across all
  publishable content. See SECURITY.md.
  CLI dispatcher (`bin/cckit`), the git-mechanics bundle (`scripts/lib`), the Claude Code
  plugin, profiles, templates, the `AGENTS.md` agent contract, and the local gate
  (`scripts/check.sh`). Dual-licensed MIT OR Apache-2.0.
