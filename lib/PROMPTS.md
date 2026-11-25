# lib/ — library code, by layer

Three layers (decisions 45 and 55): `lib/core` for the gate, checks and helpers with no forge or
verb knowledge, `lib/forge` for the GitHub adapters, `lib/verbs` for verb implementations. Each
test sits beside the file it tests. `scripts/` keeps only forwarding stubs at the old paths.

| Rule | Check |
| --- | --- |
| New code goes under a layer; `scripts/` and `scripts/lib/` only shrink | `lib/core/layout-fence.sh` against `lib/core/layout-fence.baseline` |
| Tests sit beside the code as `<name>-test.sh` | `lib/core/test.sh` discovers `*-test.sh` under `bin/`, `scripts/` and `lib/` |
| Only `lib/forge` may call `gh` or name the GitHub API | `lib/core/forge-fence.sh` |
| Every lib helper declares an `# errors:` header; the entry points are listed in `lib/core/errors-header.exempt` | `lib/core/errors-header-test.sh` |
| Every script parses and passes shellcheck at error severity | `lib/core/check.sh` steps 1 and 1b |
| A file `cckit init` copies into a project's flat `scripts/` finds its siblings in both layouts | `lib/verbs/init-upgrade-test.sh`, `lib/forge/gh-project-test.sh` |
