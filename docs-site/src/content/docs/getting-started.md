---
title: Getting started
description: Install cckit and run your first lifecycle commands.
---

## Install

**One-liner** (macOS · Linux · WSL — no npm or brew needed):

```bash
curl -fsSL https://raw.githubusercontent.com/jeiemgi/cckit/main/scripts/web-install.sh | bash
```

**Homebrew** (once the tap is published):

```bash
brew tap jeiemgi/cckit && brew install cckit
```

**npm** (the bare `cckit` name is taken, so cckit is scoped):

```bash
npm install -g @jeiemgi/cckit
```

**From source:**

```bash
git clone https://github.com/jeiemgi/cckit.git
cd cckit && ./scripts/install.sh    # symlinks bin/cckit onto your PATH
```

### Platforms & requirements

| Platform | Supported |
| -------- | --------- |
| macOS    | ✅ native |
| Linux    | ✅ native |
| Windows  | ✅ via WSL or Git Bash (not native cmd/PowerShell) |

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
