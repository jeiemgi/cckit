---
name: kit-add
description: Add an optional tool or a module to this project through `cckit add` — list what can be added, ask the one question its descriptor defines, and set only that key in the project config.
when_to_use: When the user wants to add, enable, set up or try an integration or a module ("add the code graph", "what can I add", "make this a software project"). SKIP when they want a package dependency (pnpm add), a new skill or agent (/kit-customize), or first-time setup (/kit-onboard).
---

# kit-add — one entry to every integration and module

Plugin-direct skill — helpers resolve from `${CLAUDE_PLUGIN_ROOT}`. The verb is `cckit add`
(`scripts/kit-add.sh`); this skill is the conversational way in, and it never writes config by hand.

Two kinds of thing can be added, through the same entry:

| Kind | Described by | What `add` writes |
| --- | --- | --- |
| **Integration** — an optional third-party tool | `integrations/<id>.json` | the one config key the descriptor names (`config.key`), in the project config `kit_config_path` resolves, plus each rule the descriptor lists (`rules`) into `.claude/rules/` |
| **Module** — e.g. `software` | `modules/<name>.json` | this directory's `.claude/kit.config.json`: `modules[]` plus the wizard answers |

`cckit add <integration>` **installs nothing.** It records the choice; the tool's install is a
separate step.

## Steps

1. **List.** `cckit add --llm` returns
   `{"integrations":[{id,label,summary,key,enabled,applies}],"modules":[{id,label}]}`.
   If the user named nothing, show the list and let them pick. Do not offer an integration whose
   `applies` is `false` — the tool cannot work on this repo — and say which one was left out.
2. **Render the question.** `scripts/lib/kit-interview.sh --render <name> --dir <project-dir>`.
   A module returns its wizard. An integration returns one question, `enable`, derived from its
   descriptor, with the attribution notice in `intro` and the tool's docs link in `docs`.
3. **Ask with AskUserQuestion** — one batched round, using each question's `header`, `question`
   and `options`. Put an option marked `recommended` first and label it "(Recommended)". For an
   integration, show the `intro` notice and the `docs` link with the question: it is a third-party
   tool and the user should see who makes it before saying yes.
4. **Preview, then persist.** Write the answers as `{"<key>":"<value>"}` to a temp file and run
   `KIT_DRY_RUN=1 cckit add <name> --answers <file>` to show the diff, then the same command
   without `KIT_DRY_RUN`. For an integration the preview also lists the rule files, the install
   candidates in order and the wire command; show those too. Add `--dir <project-dir>` when not in the project root.
5. **Report** the config path, the key that changed and any rule file written. For an
   integration, say that nothing was installed.

## What the verb refuses

| Case | Result |
| --- | --- |
| An `appliesWhen` condition does not hold: no file with a listed extension (`anyExtension`), or the wrong machine (`platform`) | declined, exit 0, nothing written |
| No project config found from the directory | exit 1 — run `cckit init` first; `add` does not invent a config for an integration |
| The descriptor fails `integrations/integration.schema.json` | exit 1, the bad field is named, nothing written |
| The name is neither a module nor an integration | exit 1 |

## Rules

- **Never hand-edit the config** to switch an integration on — go through `cckit add`.
- **Idempotent.** A second run with the same answer leaves the file byte-identical.
- Answering `no` to an integration writes nothing; it does not switch off one that is already on.
- An integration add changes one config key. If the diff in step 4 shows more than that key, stop
  and report it instead of applying. Rule files are separate: an existing one is never overwritten.
- A module is written into this directory only, never above it.
- `KIT_DRY_RUN=1` previews; `KIT_ASSUME_YES=1` accepts every default (for batch and CI).
