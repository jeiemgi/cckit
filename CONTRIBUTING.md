# Contributing to cckit

Thanks for your interest in cckit. Contributions — issues, ideas, and pull requests — are welcome.

## Where it lives

cckit is a standalone repository: **https://github.com/jeiemgi/cckit**. Contributing means opening
an issue or a pull request against this repo.

## Workflow

cckit develops itself with its own lifecycle:

```bash
cckit start <issue>          # isolated worktree + branch
# … make your change, commit early …
cckit pr <issue> "<summary>" # open the PR
```

- Branch from `develop` (the integration branch); one issue = one branch = one PR. `main` is
  releases-only. `cckit start` already branches from the configured base.
- Use [Conventional Commits](https://www.conventionalcommits.org/) — releases are cut from them.
  PRs are squash-merged, so **the PR title must be a Conventional Commit subject** (`type(scope): summary`).
  **`cckit pr` builds one for you** (derived from the issue's `kind:` label, `[Effort …]` prefix
  stripped); pass an already-conventional summary — `cckit pr <issue> "fix: guard the empty case"` —
  to set the type yourself. CI (`commitlint`) fails the PR until the title is valid; check one locally
  with `scripts/lib/commitlint.sh "feat: your summary"`.
- Run the local gate before opening a PR: `bash scripts/check.sh` (shell syntax, valid manifests,
  no stray branding, the commitlint rules). A green gate is the bar.

## Scope of changes

- **bash CLI + lib** → `bin/cckit`, `scripts/lib/*.sh`.
- **Claude Code plugin** → `skills/`, `commands/`, `.claude-plugin/`.
- **Docs** → `docs/` (published to [cckit.dev](https://cckit.dev)).

### Every lib file declares how it fails

A helper in `scripts/lib/` either propagates a failure to its caller or swallows it. Both are
correct — a logger that breaks the op it logs is worse than a lost log line — but a caller mixing
the two silently inherits the weaker behaviour. So each file states which it is, on one greppable
line at the end of its header comment:

```
# errors: best-effort — warns and returns 0 so a failed post never breaks the PR flow
```

| Value | Meaning |
| --- | --- |
| `pure` | No network, no state mutation, no side effects; deterministic on its args/stdin. Safe to call anywhere. The kit's baseline tools (`git`, `jq`, `date`, coreutils) are assumed present — a helper that shells out to one of them is still `pure`, because the whole CLI already requires them. Reach for `strict` when the helper depends on something that may genuinely be missing (`gh`, auth, a network call). |
| `strict` | A failed dependency or API call returns non-zero. A call that could not run is never reported as a clean result. |
| `best-effort` | Warns on stderr and returns 0, so the calling op is never broken. |
| `mixed` | Both, per function — the reason says which half is which. |

The reason after the em dash is required, not decorative: for a `mixed` file it is the only thing
telling a reader which functions propagate. `scripts/lib/errors-header-test.sh` fails on a missing
header, a value outside the vocabulary, or a bare value with no reason — so a new lib file cannot
land without one.

## License

By contributing, you agree that your contributions are dual licensed under MIT OR Apache-2.0
(see [LICENSE-MIT](LICENSE-MIT) and [LICENSE-APACHE](LICENSE-APACHE)), matching the project.
