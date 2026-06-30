---
title: Showcase
description: Every cckit capability at a glance — real command output captured as screenshots.
---

A short visual tour of cckit — each shot is a real command run for real, captured at the same
size. For the **full command list** (copyable), see the [CLI reference](/cli-reference/); to
see how the verbs fit together, start with [the GitHub cycle](/github-cycle/).

## At a glance

### The installed version

```bash
cckit version
```

![The installed version](/showcase/version.png)

### Detect this repo's stack + kit state

```bash
cckit scan
```

![Detect this repo's stack + kit state](/showcase/scan.png)

### Thin dashboard — board, worktrees, handoff

```bash
cckit status
```

![Thin dashboard — board, worktrees, handoff](/showcase/status.png)

### Plan N parallel flows (dry-run)

```bash
cckit orchestrate --dry-run 46 47 48
```

![Plan N parallel flows (dry-run)](/showcase/orchestrate.png)

### Compact uniform JSON into TOON

```bash
echo '[…uniform array…]' | cckit encode-context
```

![Compact uniform JSON into TOON](/showcase/encode-context.png)

