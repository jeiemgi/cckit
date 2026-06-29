---
title: Releasing
description: SemVer + Conventional Commits versioning, with auto-release on merge.
---

cckit follows **[Semantic Versioning](https://semver.org/)** driven by
**[Conventional Commits](https://www.conventionalcommits.org/)**. Versioning is automatic: the
commit messages on `main` decide the next version, so there is no manual "what number is this" step.

## How the version is decided

`scripts/lib/version-bump.sh` is the single source of the bump rules (shared by `cckit release` and
the release workflow). It looks at every commit since the last tag and picks the highest bump:

| Commit | Bump | Example |
| --- | --- | --- |
| `feat!:` / `type!:` / a `BREAKING CHANGE:` footer | **major** | `1.4.2 -> 2.0.0` |
| `feat:` | **minor** | `1.4.2 -> 1.5.0` |
| `fix:` / `perf:` / `refactor:` / `revert:` / anything else | **patch** | `1.4.2 -> 1.4.3` |
| no commits since the tag | **none** | no release |

Check what the next version would be at any time:

```sh
cckit release --next        # or: scripts/lib/version-bump.sh --next
```

## Auto-release on merge

`.github/workflows/release.yml` runs on every merge to `main`:

1. compute the bump from the commits since the last tag;
2. if release-worthy, bump the version in `cckit.config.json`, `.claude-plugin/plugin.json`, and
   `package.json`;
3. commit `chore(release): vX.Y.Z`, tag `vX.Y.Z`, push, and cut a GitHub Release with generated
   notes.

The workflow ignores its own `chore(release):` commit, so it never loops. A merge with only
`chore`/`docs`-style noise still patches; a merge with no new commits releases nothing.

> Workflow changes are always human-reviewed (the CI token's blast radius). This file ships the
> workflow; a maintainer merges the PR that adds or edits it.

## Publishing to npm + Homebrew

The GitHub Release is automatic; pushing the package is a deliberate, credentialed step:

```sh
cckit release X.Y.Z              # DRY RUN — prints the full plan, changes nothing
cckit release X.Y.Z --publish    # tag + GitHub release + Homebrew formula + npm (needs tokens)
```

Wiring npm/brew publishing into the workflow (behind repo secrets) is a follow-up; until then it is
the one manual step, and it is safe-by-default (dry-run unless `--publish`).

## Commit message rules (the contract)

- Every commit on a PR uses a Conventional Commit subject: `type(scope): summary`.
- Breaking changes use `!` after the type/scope **or** a `BREAKING CHANGE:` footer — never a silent
  major.
- Keep one logical change per commit so the generated release notes read cleanly.
