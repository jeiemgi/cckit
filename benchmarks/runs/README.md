# Recorded benchmark checkpoints

One file per release version: `<X.Y.Z>.json`. A file holds every checkpoint taken while that version
was being built. Write these files with `cckit bench checkpoint <X.Y.Z>`, not by hand.

```json
{
  "schema": 1,
  "version": "0.10.0",
  "checkpoints": [
    {
      "n": 1,
      "date": "2026-11-12",
      "ref": "develop",
      "commit": "38981dc",
      "model": "claude-haiku-5-5",
      "passes": 1,
      "questions": 18,
      "total": 18,
      "pass": 14,
      "score_pct": 77,
      "tiers": { "retrieval": { "total": 12, "pass": 9 } },
      "note": "",
      "results": [
        { "set": "retrieval.jsonl", "tier": "retrieval", "id": "ret-01", "q": "…",
          "expect": "docs/releasing.md", "got": "docs/releasing.md",
          "passed": 1, "asked": 1, "pass": true, "latency_ms": 8000 }
      ]
    }
  ]
}
```

| Field | Meaning |
| --- | --- |
| `n` | position in the version, from 1; a new checkpoint gets the next number |
| `ref`, `commit` | the branch and short commit the run was made on |
| `passes` | how many times every question was asked |
| `questions` | questions in the run |
| `total`, `pass` | answers asked (`questions` × `passes`) and answers right |
| `score_pct` | `pass` × 100 / `total`, rounded down; display only |
| `results[].passed`, `.asked` | per question: passes answered right, of passes asked |
| `results[].pass` | true only when every pass was right |
| `results[].got` | the answer of the first pass that missed, else the last answer |

`cckit bench check <X.Y.Z>` compares `pass`/`total` of the version's last checkpoint with the
checkpoint recorded before it, as fractions. `cckit release <X.Y.Z>` refuses on a missing file or a
lower score. Files whose name is not `X.Y.Z.json` are ignored. A file named `X.Y.Z.json` that is not
valid JSON with a `checkpoints` array stops every checkpoint verb with exit 2 and its path on stderr.

A run with an empty `got` is refused (exit 2): `cckit bench run` stores an empty answer only when
the model backend failed.

The public page `docs-site/src/content/docs/benchmark-results.md` is generated from these files
(`cckit bench page`); `scripts/benchmark/checkpoint-test.sh` fails when it differs.
