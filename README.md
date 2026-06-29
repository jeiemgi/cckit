# cckit

> A project operating system for coding agents — the full GitHub work lifecycle as a CLI, drivable by Claude Code and any other agent.

[![License: MIT OR Apache-2.0](https://img.shields.io/badge/license-MIT%20OR%20Apache--2.0-blue.svg)](#license)
[![Built for Claude Code](https://img.shields.io/badge/built%20for-Claude%20Code-8A63D2.svg)](https://docs.claude.com/claude-code)
[![Docs](https://img.shields.io/badge/docs-cckit.dev-0A7E8C.svg)](https://cckit.dev)

**[📖 Documentation](https://cckit.dev)** · [Quick start](#quick-start) · [Contributing](CONTRIBUTING.md) · [Code of Conduct](CODE_OF_CONDUCT.md)

[![Deploy the docs with Vercel](https://vercel.com/button)](https://vercel.com/new/clone?repository-url=https://github.com/jeiemgi/cckit&project-name=cckit-docs&root-directory=docs-site)

cckit turns a Git repository into a structured, agent-operable workspace. It ships the entire
GitHub lifecycle — issues, branches, isolated worktrees, PRs, the merge flow, garbage collection,
and a multi-agent orchestrator — as a single bash CLI plus a Claude Code plugin (skills, rules,
agents). It is **agent-agnostic by design**: Claude Code is first-class, but any agent that can run
a shell can drive every operation.

## Why

- **One lifecycle, one source of truth.** Start an issue, get an isolated worktree and branch, open
  a PR, merge, and clean up — each step is one command, correct by construction.
- **Agent-operable.** Every verb has a machine-readable mode (`cckit <verb> --llm`) and an
  [`AGENTS.md`](AGENTS.md) contract, so agents drive the kit without scraping human output.
- **Zero hard dependencies.** Pure bash with graceful fallbacks; it auto-detects optional tools
  (`gh`, `jq`, `fzf`, `gum`) and degrades instead of failing.
- **Portable.** No company, framework, or repo is baked in — everything is driven from
  `cckit.config.json`.

## Install

```bash
# Homebrew (planned)
# brew install jeiemgi/tap/cckit

# From source
git clone https://github.com/jeiemgi/cckit.git
cd cckit && ./scripts/install.sh    # symlinks bin/cckit onto your PATH
```

Requirements: `bash` 4+, `git`, and `gh` (GitHub CLI) authenticated. `jq` recommended.

## Quick start

```bash
cckit init                 # scaffold cckit.config.json + .claude/ for this repo
cckit start 42             # isolated worktree + branch for issue #42
cckit pr 42 "what changed" # commit, push, open the PR
cckit sync                 # board state, what's unblocked
cckit gc                   # prune merged branches + worktrees
```

Run `cckit help` for the full verb list, or `cckit <verb> --help` for any one.

## Driven by agents

cckit is meant to be operated by an agent loop, not only a human. See [`AGENTS.md`](AGENTS.md) for
the contract. Every verb accepts `--llm` for structured, parseable output:

```bash
cckit sync --llm           # JSON board state for an agent to reason over
cckit effort plan --llm    # the session-fit work plan as data
```

## Documentation

Full docs, the workflows cookbook, and the API reference live at **[cckit.dev](https://cckit.dev)**.

## Project layout

```
cckit/
  bin/cckit              # the CLI dispatcher
  scripts/lib/*.sh       # the git-mechanics bundle (effort, worktree, gh, gc, …)
  .claude-plugin/        # the Claude Code plugin manifest
  skills/ commands/      # Claude Code skills + slash commands
  profiles/ templates/   # init profiles + scaffold templates
  docs/                  # documentation source (deployed to cckit.dev)
  cckit.config.json      # project configuration (no hardcoded org/repo)
```

## Built with cckit

Using cckit in your project? Add a badge (optional, but appreciated):

[![Built with cckit](https://img.shields.io/badge/built%20with-cckit-0A7E8C.svg)](https://github.com/jeiemgi/cckit)

```markdown
[![Built with cckit](https://img.shields.io/badge/built%20with-cckit-0A7E8C.svg)](https://github.com/jeiemgi/cckit)
```

More variants (HTML, flat-square): [docs/badge.md](docs/badge.md).

## Contributing

Issues and PRs welcome — see [`CONTRIBUTING.md`](CONTRIBUTING.md). cckit develops itself with its
own lifecycle (`cckit start` / `cckit pr`).

## Support

If cckit saves you time, you can support its development:

[![Buy Me a Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-jeiemgi-FFDD00?logo=buymeacoffee&logoColor=black)](https://buymeacoffee.com/jeiemgi)

## License

Licensed under either of

- MIT license ([LICENSE-MIT](LICENSE-MIT))
- Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))

at your option. Unless you explicitly state otherwise, any contribution intentionally submitted for
inclusion in cckit by you, as defined in the Apache-2.0 license, shall be dual licensed as above,
without any additional terms or conditions.
