---
description: OPT-IN export of your Claude Code sessions to redacted training JSONL — pick sessions, run the dataset builder with redaction ON, and get JSONL ready for the fine-tuning pipeline.
argument-hint: "[--match KEY ...] | [--sessions FILE ...]   (default: current project)"
allowed-tools: Bash, Read, AskUserQuestion
---

# /kit-export-training — export sessions as redacted training data

Fine-tuning a local model on your own work only helps if the data leaves the machine clean. This is
the **consent gate** in front of a dataset builder (`chat-datasets/build_dataset.py`): it lets a
builder choose which sessions to export, **always** runs the builder with redaction ON (secret /
key / token / email masking is the builder's default; this command never passes `--no-redact`), and
prints where it wrote plus a reminder that redaction must be verified before sharing.

Nothing here is automatic — it runs **only when explicitly invoked**, and it never uploads anything.
The output is plain JSONL on disk; what you do with it is your call.

Handler (under `${CLAUDE_PLUGIN_ROOT}`):
- `scripts/kit-export-training.sh [--builder PATH] [--match KEY ...] [--dirs DIR ...] [--sessions FILE ...] [--out PATH] [--split FRAC] [--final-only] [--drop-narration]`

## Steps

1. **Locate the builder (config-driven)** — the handler resolves `build_dataset.py` with NO
   hardcoded user path, in this order: `--builder PATH` → `KIT_DATASET_BUILDER` env → a sibling
   `chat-datasets/build_dataset.py` next to the git repo root. If none resolve it stops and asks for
   `--builder` / `KIT_DATASET_BUILDER`.
2. **Select what to export** — default is the **current git project** (matched by its slug under
   `~/.claude/projects`). Let the builder choose instead:
   - `--match KEY ...` — project-dir name substrings (e.g. `cckit tuempresa`)
   - `--sessions FILE ...` — individual `*.jsonl` transcripts (staged into a temp dir)
   - `--dirs DIR ...` — explicit `~/.claude/projects/<dir>` directories
3. **Confirm (opt-in)** — on a TTY the handler asks before writing anything; aborting writes
   nothing. Use AskUserQuestion to surface the selection + output path for an explicit yes.
4. **Build with redaction ON** — runs `build_dataset.py` with masking (the builder's default; there
   is deliberately **no `--no-redact` passthrough**). Optional `--split`, `--final-only`,
   `--drop-narration` pass straight through.
5. **Report** — prints the JSONL path, the sidecar `*.stats.json` (includes a `redactions_applied`
   tally), and the train/valid split dir if `--split` was used.
6. **Remind** — redaction is applied automatically but is **not a guarantee**; the user must verify
   the output for leftover secrets, tokens, private names, or customer data **before sharing**.

## Rules

- **Opt-in only** — never runs unprompted; never uploads. Output is local files.
- **Redaction is always on** — this command exists to enforce that; do not add a way to disable it.
- **Builder path is config-driven** — `--builder` / `KIT_DATASET_BUILDER` / sibling discovery; never
  hardcode an absolute path.
- **Default output** — `~/.claude/exports/<slug>-training.jsonl` unless `--out` is given.
- Honors `KIT_ASSUME_YES` (skip the final confirm, for batch/CI).
