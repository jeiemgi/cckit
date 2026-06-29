---
title: Showcase
description: Every cckit capability at a glance — real command output captured as screenshots.
---

A live tour of cckit, generated from a dataset (`docs-site/showcase/showcase.json`) by
`scripts/showcase.sh`: each command is run for real and its output captured as a screenshot.
Every command here is read-only or a dry-run — safe to run yourself.

## Basics

### Print the installed version

```bash
cckit version
```

![Print the installed version](/showcase/version.png)

### Version as structured data (--llm)

```bash
cckit version --llm
```

![Version as structured data (--llm)](/showcase/version-json.png)

### The full verb list

```bash
cckit help
```

![The full verb list](/showcase/help.png)

### The command catalog

```bash
cckit commands
```

![The command catalog](/showcase/commands.png)

### Generate shell completion

```bash
cckit completions bash
```

![Generate shell completion](/showcase/completions.png)

## Board & lifecycle

### Board state — what's open and unblocked

```bash
cckit sync
```

![Board state — what's open and unblocked](/showcase/sync.png)

### Board state as data for an agent (--llm)

```bash
cckit sync --llm
```

![Board state as data for an agent (--llm)](/showcase/sync-json.png)

### Thin dashboard — board, worktrees, handoff

```bash
cckit status
```

![Thin dashboard — board, worktrees, handoff](/showcase/status.png)

## Project intelligence

### Detect this repo's stack + kit state

```bash
cckit scan
```

![Detect this repo's stack + kit state](/showcase/scan.png)

### Stack + kit state as JSON (--llm)

```bash
cckit scan --llm
```

![Stack + kit state as JSON (--llm)](/showcase/scan-json.png)

### Report merged branches + worktrees

```bash
cckit gc
```

![Report merged branches + worktrees](/showcase/gc.png)

## Orchestration

### Plan N parallel flows (dry-run)

```bash
cckit orchestrate --dry-run 46 47 48
```

![Plan N parallel flows (dry-run)](/showcase/orchestrate.png)

## Utilities

### Compact uniform JSON into TOON

```bash
echo '[…uniform array…]' | cckit encode-context
```

![Compact uniform JSON into TOON](/showcase/encode-context.png)

