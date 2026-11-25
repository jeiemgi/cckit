# docs-site/ — the documentation site

The Astro site, its media and the `kit-annotate` reference. The old `docs/` folder folded in here
(#603).

| Rule | Check |
| --- | --- |
| The CLI reference lists every verb in `lib/core/verbs.tsv` | `lib/core/verbs-test.sh` |
| The site version matches the release | `release-please-config.json` extra-files; `.release-please-manifest.json` |
| No `docs/` directory comes back | `lib/core/layout-fence.sh` (top-level allowlist) |
| Nothing private is published | the leak fence in `lib/core/check.sh` |
