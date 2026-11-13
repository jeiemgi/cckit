---
title: Benchmark results
description: The documentation benchmark score recorded at every checkpoint of every release.
---

<!-- Generated from benchmarks/runs/*.json by `cckit bench page`. Do not edit by hand: scripts/check.sh fails when this page differs from the run files. -->

Each release records the [documentation benchmark](/benchmark/) as one or more checkpoints: a run, the fixes it showed were needed, then another run. A release is refused when its last checkpoint scores lower than the checkpoint recorded before it, counted over the questions both checkpoints asked ([Releasing](/ship/releasing/#the-benchmark-check)).

Score is answers right out of answers asked. A checkpoint with more than one pass asks every question that many times.

## 0.10.0

| Checkpoint | Date | Commit | Model | Passes | Score | Retrieval | Adversarial | Abstain |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 2026-11-12 | `develop@38981dc` | claude-haiku-5-5 | 1 | **14/18** (77%) | 9/12 | 2/3 | 3/3 |
| 2 | 2026-11-12 | `fix/458@89200dd` | claude-haiku-5-5 | 1 | **18/18** (100%) | 12/12 | 3/3 | 3/3 |
| 3 | 2026-11-12 | `develop@c462add` | claude-haiku-5-5 | 1 | **18/18** (100%) | 12/12 | 3/3 | 3/3 |

Checkpoint 1 missed 4 of 18 questions:

| Question | Tier | Expected | Answered | Right |
| --- | --- | --- | --- | --- |
| `new-03` Which files does a Codex-only install of cckit write, compared with a Claude Code install? | retrieval | `docs-site/src/content/docs/install-matrix.mdx` | `docs-site/src/content/docs/adapters.mdx` | 0/1 |
| `new-04` How does cckit stop two live sessions from starting work on the same issue? | retrieval | `docs-site/src/content/docs/multi-session.mdx` | `docs-site/src/content/docs/cli-reference.mdx` | 0/1 |
| `new-05` Which rules does cckit ship into a project, and which of them are path-scoped? | retrieval | `docs-site/src/content/docs/rules.mdx` | `docs-site/src/content/docs/review-gates.mdx` | 0/1 |
| `adv-01` Two of my helpers grabbed the same ticket at once. What in the tool prevents that? | adversarial | `docs-site/src/content/docs/multi-session.mdx` | `cli-reference.mdx` | 0/1 |

Checkpoint 2: no missed questions.

Checkpoint 3: no missed questions.

## 0.9.0

| Checkpoint | Date | Commit | Model | Passes | Score | Retrieval | Adversarial | Abstain |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 2026-11-12 | `v0.9.0@1885252` | claude-haiku-5-5 | 1 | **10/18** (55%) | 6/12 | 1/3 | 3/3 |

Checkpoint 1 missed 8 of 18 questions:

| Question | Tier | Expected | Answered | Right |
| --- | --- | --- | --- | --- |
| `new-01` How do I boot one QA stack per wave and record a QA verdict before merge? | retrieval | `docs-site/src/content/docs/qa-lane.mdx` | `NONE` | 0/1 |
| `new-02` How do I add an optional third-party tool such as a code graph to my project? | retrieval | `docs-site/src/content/docs/integrations.mdx` | `NONE` | 0/1 |
| `new-03` Which files does a Codex-only install of cckit write, compared with a Claude Code install? | retrieval | `docs-site/src/content/docs/install-matrix.mdx` | `NONE` | 0/1 |
| `new-04` How does cckit stop two live sessions from starting work on the same issue? | retrieval | `docs-site/src/content/docs/multi-session.mdx` | `wave.mdx` | 0/1 |
| `new-05` Which rules does cckit ship into a project, and which of them are path-scoped? | retrieval | `docs-site/src/content/docs/rules.mdx` | `NONE` | 0/1 |
| `new-06` How do I cherry-pick an already merged fix onto the release branch as a hotfix? | retrieval | `docs-site/src/content/docs/releasing.mdx` | `NONE` | 0/1 |
| `adv-01` Two of my helpers grabbed the same ticket at once. What in the tool prevents that? | adversarial | `docs-site/src/content/docs/multi-session.mdx` | `wave.mdx` | 0/1 |
| `adv-02` I want the thing to keep working while I sleep, but with a spending ceiling. Where is that explained step by step? | adversarial | `docs-site/src/content/docs/tutorials/run-claude-code-unattended.mdx` or `docs-site/src/content/docs/config-and-permissions.mdx` | `NONE` | 0/1 |

