---
title: Benchmark results
description: The documentation benchmark score recorded at every checkpoint of every release.
---

<!-- Generated from benchmarks/runs/*.json by `cckit bench page`. Do not edit by hand: scripts/check.sh fails when this page differs from the run files. -->

Each release records the [documentation benchmark](/benchmark/) as one or more checkpoints: a run, the fixes it showed were needed, then another run. A release is refused when its last checkpoint scores lower than the checkpoint recorded before it, counted over the questions both checkpoints asked ([How cckit itself is released](/releasing-cckit/#the-benchmark-check)).

Score is answers right out of answers asked. A checkpoint with more than one pass asks every question that many times.

## 0.10.0

| Checkpoint | Date | Commit | Model | Passes | Score | Retrieval | Adversarial | Abstain |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 2026-11-12 | `develop@38981dc` | claude-haiku-5-5 | 1 | **14/18** (77%) | 9/12 | 2/3 | 3/3 |
| 2 | 2026-11-12 | `fix/458@89200dd` | claude-haiku-5-5 | 1 | **18/18** (100%) | 12/12 | 3/3 | 3/3 |
| 3 | 2026-11-12 | `develop@c462add` | claude-haiku-5-5 | 1 | **18/18** (100%) | 12/12 | 3/3 | 3/3 |
| 4 | 2026-11-13 | `feat/452-benchmarks-run-and-are-published-with-ev@5ae1132` | claude-haiku-5-5 | 1 | **50/55** (90%) | 29/32 | 12/14 | 9/9 |

Checkpoint 1 missed 4 of 18 questions:

| Question | Tier | Expected | Answered | Right |
| --- | --- | --- | --- | --- |
| `new-03` Which files does a Codex-only install of cckit write, compared with a Claude Code install? | retrieval | `docs-site/src/content/docs/install-matrix.mdx` | `docs-site/src/content/docs/adapters.mdx` | 0/1 |
| `new-04` How does cckit stop two live sessions from starting work on the same issue? | retrieval | `docs-site/src/content/docs/multi-session.mdx` | `docs-site/src/content/docs/cli-reference.mdx` | 0/1 |
| `new-05` Which rules does cckit ship into a project, and which of them are path-scoped? | retrieval | `docs-site/src/content/docs/rules.mdx` | `docs-site/src/content/docs/review-gates.mdx` | 0/1 |
| `adv-01` Two of my helpers grabbed the same ticket at once. What in the tool prevents that? | adversarial | `docs-site/src/content/docs/multi-session.mdx` | `cli-reference.mdx` | 0/1 |

Checkpoint 2: no missed questions.

Checkpoint 3: no missed questions.

Checkpoint 4 missed 5 of 55 questions:

| Question | Tier | Expected | Answered | Right |
| --- | --- | --- | --- | --- |
| `ret-09` When the headless single-objective runner stops, which exit code means a round changed nothing, and what are the other stop reasons? | retrieval | `docs-site/src/content/docs/agent-compatibility.mdx` | `docs-site/src/content/docs/development/run-one-objective-unattended.mdx` | 0/1 |
| `new-13` The guard scripts installed for Codex never fire. What do I have to do inside Codex first, and can cckit doctor confirm that they run? | retrieval | `docs-site/src/content/docs/hooks.mdx` | `docs-site/src/content/docs/getting-started/codex.mdx` | 0/1 |
| `new-18` Which pull requests does the ordinary merge command refuse outright, and what do I run for them? | retrieval | `docs-site/src/content/docs/project-management/efforts-and-waves.mdx` or `docs-site/src/content/docs/effort-reference.mdx` or `docs-site/src/content/docs/cli-reference.mdx` | `docs-site/src/content/docs/ship/merge-and-close.mdx` | 0/1 |
| `adv-05` The bot merged a pull request that showed no conflicts, and it silently wiped out a teammate's change that had landed just before it. Why does that happen, and which GitHub setting stops it? | adversarial | `docs-site/src/content/docs/rules.mdx` | `docs-site/src/content/docs/ship/index.mdx` | 0/1 |
| `adv-08` My work was merged days ago but its ticket still shows as open on the tracker. Why did the merge not close it? | adversarial | `docs-site/src/content/docs/rules.mdx` | `docs-site/src/content/docs/ship/index.mdx` | 0/1 |

Checkpoint 4 verb timings: wall time of each read-only verb and the number of times it ran `gh`.

| Verb | Runs | Min ms | Median ms | gh calls |
| --- | --- | --- | --- | --- |
| `cckit status` | 3 | 22870 | 24103 | 38 |
| `cckit sync` | 3 | 1536 | 1547 | 2 |
| `cckit next` | 3 | 26342 | 31425 | 47 |
| `cckit plan` | 3 | 28404 | 28715 | 47 |
| `cckit gc` | 3 | 16773 | 19102 | 31 |
| `cckit effort plan` | 3 | 1937 | 1953 | 4 |
| `cckit claims` | 3 | 227 | 230 | 0 |
| `cckit task list` | 3 | 578 | 597 | 0 |
| `cckit qa lanes` | 3 | 69 | 69 | 0 |

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

