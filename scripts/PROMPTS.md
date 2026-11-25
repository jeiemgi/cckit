# scripts/ — forwarding stubs

The code moved to `lib/` in #600-#604. What is left at a file path directly under `scripts/` or
`scripts/lib/` is a forwarding stub: installed projects, CI and `kit/` call these paths, so each
stub forwards (run, or sourced from bash or zsh) to the moved file. The stubs go in the release
after 0.13 (decision 66). `scripts/benchmark/` is the harness `cckit init` copies, not yet moved.

| Rule | Check |
| --- | --- |
| A file directly under `scripts/` or `scripts/lib/` is a forwarding stub or a symlink | `lib/core/layout-fence.sh` |
| The stub count may not grow; a removed stub lowers the baseline in the same change | `lib/core/layout-fence.sh` (`scripts-top`, `scripts-lib`) |
| Paths named by the installed payload under `kit/` keep resolving | `lib/core/self-install-test.sh`, `lib/verbs/kit-doctor-test.sh` |
| Everything passes the local gate | `bash scripts/check.sh` |
