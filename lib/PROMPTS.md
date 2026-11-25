# lib/ — library code, by layer

The target layers (decisions 45 and 55): `lib/core` for checks and helpers with no forge or verb
knowledge, `lib/forge` for the GitHub adapters, `lib/verbs` for verb implementations. Code moves
here from `scripts/` and `scripts/lib/` by ratchet: expand, migrate the callers, contract.

| Rule | Check |
| --- | --- |
| A file moved out of `scripts/` lowers the layout baseline in the same change | `lib/core/layout-fence.sh` against `lib/core/layout-fence.baseline` |
| Tests sit beside the code as `<name>-test.sh` | `lib/core/test.sh` discovers `*-test.sh` under `bin/`, `scripts/` and `lib/` |
| Only `lib/forge` may call `gh` or name the GitHub API | `lib/core/forge-fence.sh` |
| Every script parses and passes shellcheck at error severity | `lib/core/check.sh` steps 1 and 1b |
| A moved script keeps a forwarding stub at its old path for one release, because installed projects call it by path | review; the stub is removed in the release after |
