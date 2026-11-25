# Security

## Built-in secret + privacy guard

cckit ships an agnostic guard that prevents secrets, key material, env files, and **your** private
project data from ever being committed or published — across all content (code, docs, cookbook,
examples, templates):

- **`lib/core/secret-guard.sh`** — scans for forbidden files (`.env*` including `.env.example`,
  `*.pem`/`*.key`/keystores, `id_rsa`, `.netrc`, `*.tfvars`, …) and universal secret patterns
  (provider key prefixes, private-key blocks, JWTs, secret assignments).
- **Your private denylist** — copy `privacy-denylist.example` to `.cckit/privacy-denylist`
  (gitignored) and list terms private to you (org, hosts, emails). Nothing project-specific is
  hardcoded in cckit; you declare what is yours.
- **The leak fence** (`lib/core/leak-fence.sh`, gate step 3) — fails on any tracked line that
  contains a private word: a product name, a client, a person, a private path. The built-in pattern
  is always on; yours go in `.cckit/leak-words` (local, gitignored, one extended regex per line) or
  the `CCKIT_LEAK_WORDS` repository secret for CI. The list is never committed, and a hit prints
  `file:line` without the matched text, so a public CI log cannot leak it either.
- **Enforcement** — runs in the local gate (`lib/core/check.sh`) and as a pre-commit hook
  (`kit/githooks/pre-commit`; enable with `git config core.hooksPath githooks`). A finding blocks the
  commit.

## Reporting a vulnerability

Please open a private security advisory on the repository (Security → Advisories), or a regular
issue if it is low-risk. Do not include secrets or exploit details in a public issue.
