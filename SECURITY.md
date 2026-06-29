# Security

## Built-in secret + privacy guard

cckit ships an agnostic guard that prevents secrets, key material, env files, and **your** private
project data from ever being committed or published — across all content (code, docs, cookbook,
examples, templates):

- **`scripts/lib/secret-guard.sh`** — scans for forbidden files (`.env*` including `.env.example`,
  `*.pem`/`*.key`/keystores, `id_rsa`, `.netrc`, `*.tfvars`, …) and universal secret patterns
  (provider key prefixes, private-key blocks, JWTs, secret assignments).
- **Your private denylist** — copy `privacy-denylist.example` to `.cckit/privacy-denylist`
  (gitignored) and list terms private to you (org, hosts, emails). Nothing project-specific is
  hardcoded in cckit; you declare what is yours.
- **Enforcement** — runs in the local gate (`scripts/check.sh`) and as a pre-commit hook
  (`githooks/pre-commit`; enable with `git config core.hooksPath githooks`). A finding blocks the
  commit.

## Reporting a vulnerability

Please open a private security advisory on the repository (Security → Advisories), or a regular
issue if it is low-risk. Do not include secrets or exploit details in a public issue.
