# bin/ — the dispatcher

`bin/cckit` routes a verb to its implementation. It holds argument parsing and dispatch, not the
work.

| Rule | Check |
| --- | --- |
| Every verb row in `lib/core/verbs.tsv` has a case label here, and every case label has a row | `scripts/verbs-test.sh` |
| The verb count may not grow without lowering the baseline in the same change | `lib/core/verbs-ratchet.sh` against `lib/core/verbs.baseline` |
| No GitHub call outside the forge layer | `lib/core/forge-fence.sh` |
| No force push | `lib/core/force-push-fence.sh` |
| A new verb's implementation is named in the feature map | `lib/core/feature-map.sh --check` |
