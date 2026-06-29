---
title: Security & secret guard
description: cckit's built-in, agnostic guard against publishing secrets, keys, env files, or your private data.
---

cckit ships an agnostic guard that prevents secrets, key material, env files, and **your** private
project data from ever being committed or published — across all content (code, docs, cookbook,
examples, templates).

## What it blocks

- **Forbidden files** — `.env*` (including `.env.example`), `*.pem` / `*.key` / keystores,
  `id_rsa`, `.netrc`, `*.tfvars`, project id dumps.
- **Secret content** — provider key prefixes, private-key blocks, JWTs, and secret-looking
  assignments (placeholders like `<...>` / `${...}` / `YOUR_…` are allowed).
- **Your private terms** — a denylist you control.

## Your private denylist (agnostic)

Nothing project-specific is hardcoded in cckit. Copy `privacy-denylist.example` to
`.cckit/privacy-denylist` (gitignored) and list terms private to you (org, hosts, emails). The guard
fails if any appear in a tracked file. cckit ships the list **empty** — you declare what is yours.

## Enforcement

The guard runs in the local gate (`scripts/check.sh`) and as a pre-commit hook
(`githooks/pre-commit`; enable with `git config core.hooksPath githooks`). A finding blocks the
commit.

## Reporting a vulnerability

Open a private security advisory on the repository (Security → Advisories), or a regular issue if it
is low-risk. Do not include secrets or exploit details in a public issue.
