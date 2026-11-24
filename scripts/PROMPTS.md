# scripts/ — the old root, draining into lib/

Verb implementations, the gate (`check.sh`, `test.sh`) and their tests. New code goes under
`lib/`; this directory only shrinks.

| Rule | Check |
| --- | --- |
| The file count directly under `scripts/` and under `scripts/lib/` may not grow | `lib/core/layout-fence.sh` (`scripts-top`, `scripts-lib`) |
| A drop lowers the baseline in the same change | the same fence fails on a stale baseline |
| Paths named by the installed payload under `kit/` keep resolving | `scripts/self-install-test.sh`, `scripts/kit-doctor-test.sh` |
| Everything passes the local gate | `bash scripts/check.sh` |
