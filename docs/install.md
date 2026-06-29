# Installing cckit

cckit is pure bash over `git`, `gh`, and `jq`. There is no build step — installing it just puts the
`cckit` dispatcher on your PATH. Pick whichever fits.

## Global install

```sh
# from a clone:
./scripts/install.sh            # or: cckit install   (symlinks bin/cckit into a PATH dir)

# one-liner (no clone):
curl -fsSL https://cckit.dev/install.sh | bash      # scripts/web-install.sh

# Homebrew:
brew install jeiemgi/cckit/cckit                    # Formula/cckit.rb
```

`cckit install [bin-dir]` symlinks `bin/cckit` into the first writable PATH dir
(`~/.local/bin`, then `/usr/local/bin`, then `~/bin`), or a dir you pass. It is a **symlink, not a
copy** — the dispatcher resolves the link back to the repo, so `git pull` upgrades your install with
no reinstall.

Verify:

```sh
cckit version       # prints the installed version
cckit doctor        # preflight: git/gh/jq present, gh authenticated
```

## Dependencies

| Required | Why |
| --- | --- |
| `git`, `gh`, `jq` | the lifecycle (worktrees, GitHub, JSON) |
| `bash` 3.2+ | the dispatcher + lib |

Optional, auto-detected (never required): `tmux` (orchestrate), `glow`/`fzf`/`gum` (native UX),
Node + Chrome (`cckit debug` via chrome-devtools-axi). `cckit doctor` reports what's missing.

## Per-repo setup

Installing puts `cckit` on PATH globally; **adopting it in a repo** is a separate, per-repo step:

```sh
cckit scan          # what's here already
cckit init          # scaffold cckit.config.json + .claude/ (greenfield)
```

See [adoption.md](adoption.md) for adopting an existing kit-shaped repo.

## Claude Code (IDE) config

cckit ships as a Claude Code plugin (`.claude-plugin/plugin.json` + `commands/` + `skills/`). With
the repo present, Claude Code discovers the `/kit-*` slash commands and skills. `cckit init`
scaffolds a project's `.claude/` (agents, hooks, rules, settings) from a profile, so the editor
picks up the kit's conventions. Other agents drive the same CLI via [AGENTS.md](../AGENTS.md) — no
IDE required.

## Safety / permission gate

Every contribution and release runs the local gate first — `scripts/check.sh` (shell syntax, valid
manifests, no stray branding) plus the **secret + privacy guard** (`scripts/lib/secret-guard.sh`:
blocks env files, keys, tokens, and a user-declared `.cckit/privacy-denylist`). Nothing publishable
leaves without passing it. The git hook in `githooks/pre-commit` wires the same guard at commit
time.
