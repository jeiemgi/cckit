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

## License

By contributing, you agree that your contributions are dual licensed under MIT OR Apache-2.0
(see [LICENSE-MIT](LICENSE-MIT) and [LICENSE-APACHE](LICENSE-APACHE)), matching the project.
