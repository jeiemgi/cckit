---
title: Config & permissions
description: How cckit discovers config, scans a project, and asks permission before it mutates anything.
---

How cckit discovers its config, scans a project, asks permission before it mutates anything, and
identifies the user — all project-agnostic.

## Config resolution (nearest wins)

1. `$KIT_CONFIG` (explicit override)
2. `cckit.config.json` at the repo root
3. an ancestor `.cckit/config.json` (per-folder override, like `.editorconfig`)

No org, repo, or path is hardcoded — every value comes from this file. A repo with no config is
invited to run `cckit init`.

## Project scanning

cckit detects the project it is pointed at from the filesystem, not from baked-in knowledge: the repo
root (`git rev-parse --show-toplevel`), stack hints (`package.json` / `pyproject.toml` / `go.mod` /
`Cargo.toml`), and kit state (`cckit.config.json`, `.claude/`, `.cckit/`).

## The permission gate (ask before operating)

- **Read-only by default in an unknown repo.** Before the first *mutating* op in a repo cckit has not
  operated in, it records consent in `.cckit/consent` (gitignored).
- **The secret/privacy guard always runs** before anything is committed or published — see
  [Security](/security/). It is not optional and not bypassed by consent.
- **Destructive/irreversible ops** (force-push, repo create, history rewrite) always require an
  explicit, separate confirmation.

## Identity

cckit asks the user their name on first run and stores it in `.cckit/identity` (gitignored). Nothing
personal is hardcoded; commits use the local git identity.
