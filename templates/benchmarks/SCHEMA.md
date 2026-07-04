# Benchmark datasets — schema

This folder is your project's **documentation benchmark**: a set of questions that measure how well
an agent starting cold can **find and use your own canonical docs** (rules, ADRs, wiki pages). cckit
ships the *runner* and this *example set*; the data is **per-project** — you grow it.

Run it after any docs or kit-version change to catch retrieval / routing / findability regressions.

## Files

| File | Tier | What it tests | Scoring |
| --- | --- | --- | --- |
| `retrieval.jsonl`   | retrieval    | plain question → the one canonical doc | objective top-hit path match |
| `adversarial.jsonl` | adversarial  | paraphrased / no-keyword / split / trap | objective top-hit path match |
| `abstain.jsonl`     | abstain      | unanswerable → agent must return NONE | any path returned = fail |
| `quality.jsonl`     | quality      | claim-style answer correctness | model judge, 0..1, mean |
| `benchmark.config.json` | — | lists the sets, the knowledge dir, and the autopilot targets | — |

Each `*.jsonl` file has **one JSON object per line**. Blank lines and `#` comment lines are ignored,
so you can annotate freely.

## Record shapes

**Retrieval / adversarial** — `expect` is a path relative to the knowledge dir, or an array of
acceptable paths (use an array when the answer is legitimately split across docs):

```json
{"id": "ret-01", "q": "How do we cut a release?", "expect": "releasing.md"}
{"id": "adv-04", "q": "Where do we write down a design decision?", "expect": ["adr/README.md", "architecture.md"]}
```

**Abstain** — there is no documented answer; the agent must not invent one. `expect` is always
`"NONE"`, and returning *any* path fails the record:

```json
{"id": "abs-01", "q": "What is the DB admin password?", "expect": "NONE"}
```

**Quality** — a claim-style prompt plus a `must` rubric (the required points). The judge scores the
answer's coverage of those points, not its tone — the rubric is what de-biases the judge:

```json
{"id": "qual-01", "claim": "Summarize our release process.", "must": ["version bumped", "changelog updated", "tag published"]}
```

## Path matching

Matching is lenient about *where* a path is rooted (a leading `./` or a leading knowledge-dir prefix
is stripped) and about basename equality, but strict about *which* document is named. So
`knowledge/releasing.md`, `releasing.md`, and `./releasing.md` all match the expected `releasing.md`.

## Running

```bash
# offline shape check (no model) — run in CI / the no-mistakes gate
scripts/benchmark/run.sh --dry
scripts/benchmark/run-quality.sh --dry

# live run (uses the configured model backend)
scripts/benchmark/run.sh                 # retrieval + adversarial + abstain
scripts/benchmark/run-quality.sh         # quality (judged)
scripts/benchmark/report.sh              # writes RESULTS.md a non-expert can read
```

## Model backend (pluggable)

The backend has **no hard dependency on a provider**. Selection is by environment:

| Env | Backend |
| --- | --- |
| _(default)_ | headless `claude -p` — the $0-API subscription path |
| `BENCH_MODEL_ENDPOINT=<url>` (+ optional `BENCH_MODEL`, `BENCH_API_KEY`) | any OpenAI-compatible `/chat/completions` endpoint |
| `BENCH_BACKEND=mock` | deterministic offline stand-in (used by `--dry` / tests) |

`BENCH_TIMEOUT_SECS` (default 90) caps each model call via a portable timeout.
