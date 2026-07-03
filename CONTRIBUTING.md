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

- Branch from `main`; one issue = one branch = one PR.
- Use [Conventional Commits](https://www.conventionalcommits.org/) — releases are cut from them.
- Run the local gate before opening a PR: `bash scripts/check.sh` (shell syntax, valid manifests,
  no stray branding). A green gate is the bar; there is no required CI.

## Scope of changes

- **bash CLI + lib** → `bin/cckit`, `scripts/lib/*.sh`.
- **Claude Code plugin** → `skills/`, `commands/`, `.claude-plugin/`.
- **Docs** → `docs/` (published to [cckit.dev](https://cckit.dev)).

## License

By contributing, you agree that your contributions are dual licensed under MIT OR Apache-2.0
(see [LICENSE-MIT](LICENSE-MIT) and [LICENSE-APACHE](LICENSE-APACHE)), matching the project.
