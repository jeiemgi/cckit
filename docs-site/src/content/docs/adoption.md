---
title: Adopting cckit
description: Issue-driven, incremental adoption of cckit in any repo.
---

Adoption is **issue-driven** and incremental: file an issue for it, then walk the steps below. Every
step is a single cckit verb, so an agent can perform the whole adoption unattended and report back.

## The flow

```sh
cckit scan            # 1. detect the repo's stack + current kit state (configured / partial / claude-only / none)
cckit init            # 2. scaffold cckit.config.json + .claude/ (skip if scan says "configured")
cckit adopt           # 3. record kit-shaped files the repo ALREADY has into the ownership manifest
cckit migrate         # 4. reshuffle any old kit layout to the current one (idempotent)
cckit update          # 5. report whether the project is behind the installed cckit
cckit doctor          # 6. preflight: deps + gh auth are in place
```

1. **`scan`** tells you where you stand. `kit: configured` → cckit already runs here; `partial` /
   `claude-only` → some kit-shaped files exist but aren't owned; `none` → greenfield.
2. **`init`** is for greenfield (`none`). It writes the config + a `.claude/` from a profile.
3. **`adopt`** is the bridge for a repo that imported the kit by hand (copied a `.claude/`, ran an
   old init, a teammate pasted skills). The files are present but the **manifest** doesn't know
   them, so `update`/`remove` won't touch them. `adopt` records each at its current hash — it writes
   no content, it only takes ownership. After adopting, `update` can refresh them and removal stays
   clean. Dry-run first; it never claims your `knowledge/`, plans, or app code.
4. **`migrate`** is the codemod for layout drift — it reshuffles an old kit layout to the current
   one idempotently, surviving repeated runs.
5. **`update`** then reports whether the project trails the installed cckit version.

## Why issue-driven

Adoption changes a repo's tracked files, so it goes through the normal lifecycle: one issue → one
branch → one PR (`cckit start` / `cckit pr`). That keeps the adoption reviewable and reversible,
and the issue is the place to record which steps applied to this repo.

## Idempotent + safe

Every step is a no-op when there is nothing to do, and the file-touching ones (`init`, `adopt`,
`migrate`) are dry-run-previewable and never overwrite content they don't own. Re-running the flow
is safe.
