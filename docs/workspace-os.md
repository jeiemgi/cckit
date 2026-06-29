# claude-kit as a workspace OS

> **Status: v2 — in progress.** This document describes the **v2 workspace-OS model** (workspace
> root + config cascade + modes + modules). It is **not yet the shipped default** — the current,
> shipping model is the **per-project** kit described in [Usage](usage.md). The two are
> generations, not contradictions: today you run `/kit-init` per project ([Usage](usage.md)); this
> page is where that's heading. See the [Status](#status) section for what has landed vs. what's
> still in flight (kit-v2 effort: #770).

> One line: **a project OS for Claude Code — you say what your project is in a config; agents,
> memory, and flow come from the kit; and if the project needs software, that module is added,
> not imposed.**

Most "agent setups" assume you are building software. claude-kit does not. Your project is a
folder that's yours — notes, knowledge, plans, drafts — edited without ceremony. If one day a part
of it needs software, _that part_ (and only that part) becomes a repo managed with the full rigor
of GitHub. Software is an **island of rigor inside a free workspace**, never the whole workspace
bent to software's rules.

## The three layers

| Layer                                                        | Lives in                                   | Who changes it                         |
| ------------------------------------------------------------ | ------------------------------------------ | -------------------------------------- |
| **Engine** — skills, agents, scripts, hooks, statusline      | the plugin (installed once, at user level) | the kit, versioned via the marketplace |
| **Identity** — who you are / what this is / how strict it is | config files, resolved in cascade          | you, freely                            |
| **Modules** — software, content, research, automation        | stackable profiles (`kit add software`)    | you, on demand                         |

The engine is a **singleton**: installed once, never copied into your projects. When you run a kit
command it writes only _identity_ locally (configs, `KIT.md`, shims), each tracked in an ownership
manifest so it can be updated — or fully removed — without ever touching your work.

## The workspace

```
proyectos-claude/                 workspace root (kit.workspace.json)
  .claude/                        the "commons" — promoted skills/agents shared across projects
  proyecto-a/
    kit.config.json               identity of this project (+ mode)
    CLAUDE.md                     100% yours + one line: @.claude/kit/KIT.md
    knowledge/                    what IS — durable (mode: guided, linted)
    drafts/                       free scratch space (mode: draft, zero rules)
    plans/                        plans in plain markdown
    software-project-a/           a software island — its own git/GitHub, config, rigor
  proyecto-b/ ...
```

Claude Code natively knows only `CLAUDE.md` and `.claude/`. Everything else is just your folders;
agents read them because `KIT.md` (imported into `CLAUDE.md` with `@`) points at them. `kit-init`
creates only three: `knowledge/`, `drafts/`, `plans/`. The lifecycle runs left to right —
explore in `drafts/` → formalize in `plans/` → distill into `knowledge/` — and the **mode**
hardens along the way.

### Config cascade

Configs resolve `workspace → project → island`, nearest layer wins (the `.editorconfig` /
`.gitconfig` pattern). Ask why something behaves the way it does, anywhere:

```sh
kit-config-resolve.sh --explain '.mode'
#   value:  enforced
#   set by: proyecto-a/software-project-a/kit.config.json
#   layers (far->near): … * the file that defines it
```

### Mode — enforced but not mandatory

`mode` is a cascade key, so an island can be strict while its parent workspace is loose:

| mode       | guardrails                          | use                          |
| ---------- | ----------------------------------- | ---------------------------- |
| `draft`    | off                                 | explore freely — hooks no-op |
| `guided`   | warn, never block                   | the default                  |
| `enforced` | block (worktree-only, PR-per-issue) | serious software islands     |

`git ≠ GitHub`: versioning the workspace with local git (history/undo, never published) is
separate from publishing a software island to GitHub. Much resistance to "putting everything in
git" is really resistance to _publishing_ — the kit keeps those distinct.

## The engine, today

The kit's behavior is built from small, zero-dependency, dual-shell (bash + zsh) libraries. No
runtime dependency on any CLI framework — the engine must run on your machine, in CI, and in
Cowork with nothing extra installed.

| Piece                   | What it does                                                                                                                                                                                                 |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `kit-manifest.sh`       | Ownership manifest — path + hash + version + tier per kit-written file. `verify` → `intact / modified / missing / untracked`. The basis for safe update + uninstall.                                         |
| `kit-config-resolve.sh` | The cascade resolver, with `--explain`.                                                                                                                                                                      |
| `kit-mode.sh`           | Resolves `mode` and maps it to a gate (`block / warn / off`) hooks consume.                                                                                                                                  |
| `kit-operate.sh`        | The one operation machine: propose diff → ask permission → apply → record. Honors dry-run; never silently clobbers a file you edited.                                                                        |
| `kit-wire.sh`           | Idempotent converge — installs/repairs the statusline shim + settings + hooks, on init **and** every update (so wiring never drifts).                                                                        |
| `kit-remove.sh`         | Uninstall by manifest. Removes only what the kit installed; your `knowledge/`, `plans/`, `drafts/`, and edits are never touched. "You can leave clean."                                                      |
| `kit-promote.sh`        | Promote a project-local skill/agent up to the workspace commons to share it (copy + hash, permission required to write above the project).                                                                   |
| `kit-export-project.sh` | Export to the non-terminal surfaces — flatten `CLAUDE.md` (+ inlined tier-A `@.claude/rules`) into claude.ai custom-instructions, copy `knowledge/` for upload, and `--verify` Cowork/claude.ai portability. |
| `kit-cli.sh`            | Shared zero-dep CLI helpers (`kit_is_main` cross-shell, IO).                                                                                                                                                 |

## The three surfaces — terminal / Cowork / claude.ai

The same kit project runs on three Claude surfaces **with no hand edits** — that is the portability
contract the manifest tiering exists to keep:

| Surface                        | How it reads the project                                                                         | Portability                               |
| ------------------------------ | ------------------------------------------------------------------------------------------------ | ----------------------------------------- |
| **Terminal** (Claude Code)     | reads `CLAUDE.md` + `.claude/` from disk; runs `kit` / `scripts/*`                               | full — tier A + tier B                    |
| **Cowork** (cloud Claude Code) | same as terminal; a tier-B shim (statusline / a guard hook) may be inert but is never _required_ | tier A guaranteed; tier B best-effort     |
| **claude.ai Project**          | no filesystem — only a custom-instructions box + uploaded knowledge                              | tier A only, **via `kit-export-project`** |

- **Tier A = portable** (skills / rules / agents / commands) · **Tier B = CLI-only**
  (`statusline.sh` / `settings.json` / `hooks/` / `lib/`). The manifest records the tier per file.
- `kit export` (→ `kit-export-project.sh`) produces `claude-instructions.md` (flattened CLAUDE.md +
  inlined tier-A rules) + `project-knowledge/` (upload-ready) + a `SUPPORT-MATRIX.md`.
- `kit export --verify` is the **connection test**: it confirms every file `CLAUDE.md` leans on is
  tier-A self-sufficient (a required tier-B file is a defect that silently no-ops off-terminal).
  `/kit-doctor` runs the same check as its "surface portability" row.

## Status

This document describes the v2 model and the engine that exists today. The importer
(`kit-adopt`/`kit-migrate`, #373) and the Cowork/claude.ai export (`kit-export-project`, #376) have
landed; the interview/onboarding flow and suggested routines are in progress. Plans are GitHub
issues now (ADR-006) — the kit-v2 effort is #770 and its sub-issues.
