---
name: speckit
description: Install or identify Spec Kit (Spec-Driven Development) in this project and drive the SDD lifecycle — constitution → specify → clarify → plan → tasks → analyze → implement. Authors the constitution + template overrides from a Stack Interview, wiring the project's build standard as the feature-module override.
when_to_use: When the user wants spec-driven development, asks to "install spec kit", "set up SDD", mentions /speckit-* commands, or wants a feature built through spec → plan → tasks → implement with review gates. Also when checking whether Spec Kit is already initialized in the repo.
---

# speckit — Spec Kit setup & SDD lifecycle

## First: identify, don't reinstall

Before anything, check whether Spec Kit is already here:

```bash
ls .specify 2>/dev/null && echo "Spec Kit present" || echo "not initialized"
specify --version 2>/dev/null || echo "specify CLI not installed"
cat .specify/init-options.json 2>/dev/null   # how it was initialized
cat .specify/feature.json 2>/dev/null         # currently-active feature
```

- If `.specify/` exists → **do not re-init**. Read `init-options.json` + `integration.json`
  (for the invoke separator) and continue at the lifecycle (§4).
- If absent → go to Installation (§2), then run the Stack Interview (§7).

## Kit integration (read this project's config + stack)

```bash
source scripts/lib/kit-config.sh && load_kit_config 2>/dev/null
# Context file is CLAUDE.md (the kit already maintains it)
cat package.json 2>/dev/null   # detect which stack-gated build skills apply
```

If a **stack convention skill applies to this project's stack** (e.g. `feature-build-refine` when
`@refinedev/*` is in `package.json`, or `supabase-patterns` when `@supabase/supabase-js` is), use
its content as the Spec Kit `feature-module.md` override (§6b) instead of authoring a new one. If
none match the stack, author the override fresh from the Stack Interview (§7).

---

## 1. What Spec Kit Is

Spec Kit is a toolkit for **Spec-Driven Development (SDD)**: you write an executable
specification first, refine it into a plan and a task list, then let an AI agent implement
against those artifacts with explicit human review gates between phases.

```
constitution → specify → clarify → plan → tasks → analyze → (checklist) → implement
     │            │          │        │       │        │          │            │
   project      feature   resolve   design  ordered  consistency optional   execute
   rules        spec      ambiguity  plan    tasks    audit       QA gate    tasks
```

Each step is a slash command / skill (e.g. `/speckit-specify`). Steps write Markdown artifacts
into a per-feature folder; humans approve at gates; the agent never silently jumps ahead.

## 2. Installation

Spec Kit ships as the `specify` CLI (from `github/spec-kit`), a Python package run via `uv`.

```bash
# One-off (no install) — recommended for init:
uvx --from git+https://github.com/github/spec-kit.git specify init --here

# Or install persistently:
uv tool install specify-cli --from git+https://github.com/github/spec-kit.git
specify init --here
```

`specify init` is interactive. Script it with the answers from the Stack Interview (§7, F):

| Option            | Typical  | Meaning |
|---|---|---|
| `ai`              | `claude` | Target AI assistant (claude / copilot / gemini) |
| `integration`     | `claude` | Which assistant integration to install commands for |
| `ai_skills`       | `true`   | Install the commands as agent skills |
| `script`          | `sh`     | Helper scripts use bash (`sh`) not PowerShell (`ps`) |
| `branch_numbering`| `sequential` | Feature branches `001-`, `002-`, … (alt: `timestamp`) |
| `context_file`    | `CLAUDE.md` | Agent context file the project already uses |
| `here`            | `true`   | Initialize into the current directory |

Verify: `specify --version` and `ls .specify`.

## 3. What init creates — `.specify/` layout

```
.specify/
├── memory/constitution.md         # ★ project's non-negotiable rules (STACK-SPECIFIC — you author)
├── templates/
│   ├── constitution-template.md
│   ├── spec-template.md
│   ├── plan-template.md           # ★ pre-fill Technical Context with your stack defaults
│   ├── tasks-template.md
│   ├── checklist-template.md
│   └── overrides/                 # ★ STACK-SPECIFIC pattern docs the plan/tasks steps cite
│       ├── api-route.md
│       ├── integration-test.md
│       └── feature-module.md      #   ← use this project's build standard verbatim
├── scripts/bash/
├── specs/NNN-feature-name/        # one folder per feature (spec.md, plan.md, research.md, data-model.md, tasks.md)
├── extensions/ + extensions.yml   # optional add-ons (e.g. git auto-commit)
├── init-options.json + integration.json + feature.json
```

**The two files you customize per project:** `memory/constitution.md` and `templates/overrides/*`.

## 4. Command lifecycle

Invoked as skills/slash commands; the integration sets the separator (`-` → `/speckit-specify`).

| Command | Purpose | Writes |
|---|---|---|
| `/speckit-constitution` | Create/update governing rules | `memory/constitution.md` |
| `/speckit-specify` | NL feature → spec; creates feature branch + folder | `specs/NNN-*/spec.md` |
| `/speckit-clarify` | Up to 5 targeted questions; encode answers into spec | `spec.md` |
| `/speckit-plan` | Plan + research + data model; runs Constitution Check gate | `plan.md`, `research.md`, `data-model.md` |
| `/speckit-tasks` | Ordered, dependency-aware task list | `tasks.md` |
| `/speckit-analyze` | Non-destructive spec ↔ plan ↔ tasks consistency audit | report only |
| `/speckit-checklist` | Custom QA checklist | `checklist.md` |
| `/speckit-implement` | Execute tasks against the codebase | source code |
| `/speckit-taskstoissues` | Convert tasks into GitHub issues | GitHub issues |

**Order:** `constitution` once per project → then per feature
`specify → clarify → plan → tasks → analyze → implement`. `analyze` is a cheap safety net before `implement`.

**Review gates:** `.specify/workflows/speckit/workflow.yml` chains specify→plan→tasks→implement
with approve/reject gates after spec and after plan. Reject aborts. Keep the human in the loop
at the two highest-leverage moments.

## 5. Git extension (optional)

The git extension (`.specify/extensions.yml`, `auto_execute_hooks: true`) auto-runs git around
each command: `before_specify` → create the feature branch; `after_*` → commit that step's
artifacts. Net: every SDD step lands as its own reviewable commit on a per-feature branch.
Set `enabled: false` / `optional: true` per hook to taste.

> Note: this overlaps the kit's own `task-start` / `task-pr` branch flow. Pick one branch
> authority per project — either Spec Kit's git extension OR the kit's `task-*` skills — and
> disable the other's branch creation to avoid double-branching.

## 6. The stack-specific layer

Only two things change between projects (the constitution + the overrides) — but the build standard
they encode is only legitimate if the repo actually follows it. A constitution that mandates rules
the shipped code violates is a broken gate. **Audit conformance first**, then author.

### Conformance audit (run BEFORE 6a–6c — do not skip)

The matching stack convention skill (`feature-build-refine`, `supabase-patterns`, …) describes a
*target* architecture. The repo may already follow it, partially follow it, or use a coherent but
**different** architecture. Authoring a constitution from the skill without checking is how you end
up asserting MUST-rules the code breaks on day one.

1. **Map reality.** Inspect the actual structure against the skill's prescriptions — directory
   layout, module boundaries, the canonical form/component/handler patterns, data-access shape, and
   the items from the Stack Interview (§7). Cheap, high-signal probes: `ls src/`, find the feature
   or route folders, grep for the patterns the skill mandates (e.g. `"use server"`, the prescribed
   client paths, shared primitive dirs).
2. **Classify drift** per dimension as **conforms / partial / divergent (different architecture)**,
   with a one-line severity. Distinguish "incomplete" (missing pieces of the same pattern) from
   "divergent" (a different, internally-consistent pattern) — they reconcile differently.
3. **Decide the reconciliation** — this is the user's call when drift is non-trivial, because it
   changes what the constitution may assert. Offer:
   - **Migrate repo → standard** — refactor the code to the skill; constitution stands as authored.
   - **Amend standard → repo** — rewrite the skill + the constitution principle + `feature-module.md`
     to document the repo's actual architecture as the standard; no code moves.
   - **Hybrid** — adopt the high-value, low-risk parts of the standard, keep the rest; amend the
     constitution to bless what stays.
4. **Don't author against reality.** Never write a principle the code violates without either (a) a
   migration plan that makes it true, or (b) amending the principle to match. If the repo conforms,
   say so and proceed to 6a–6c unchanged.
5. **On migrate/hybrid, produce a migration plan** — a phased, build-green plan written per the
   `plan-output-format` rule (a file in `docs/plans`), and offer to open tracked issues (`task-new`
   / `gh`) per phase. The constitution then references the plan for the not-yet-true principles.

> This audit is also the right reflex at `/kit-init` time: the stack-gated build skills
> self-activate from `package.json` whether or not Spec Kit is installed, so drift between skill and
> repo exists the moment the kit is scaffolded — Spec Kit just makes it enforceable.

### 6a. Constitution (`memory/constitution.md`)
Supreme rule set, semver-versioned with a Sync Impact Report comment. Declares: Core Principles
(named, declarative, MUST/MUST NOT + rationale), Technology Stack, Domain Model & Business Rules,
Mandatory code patterns (pointing at overrides), Definition of Done, Governance (precedence +
amendment). The plan step runs a Constitution Check against these — vague principles = vague gates.

### 6b. Template overrides (`templates/overrides/*.md`)
Concrete, copy-exactly pattern references the plan/tasks/implement steps cite:
- `api-route.md` — canonical handler (auth → authz → validate → execute → typed errors)
- `integration-test.md` — test harness (what's mocked, what hits real infra, cleanup)
- `feature-module.md` — **use the matching stack convention skill verbatim** (`feature-build-refine`,
  `supabase-patterns`, …) when one applies to the stack; otherwise author from the Stack Interview

### 6c. Pre-fill the plan template
Edit `templates/plan-template.md` Technical Context with stack defaults and wire the
Constitution Check checkboxes to the actual Core Principles, so every plan starts correct.

## 7. Stack Interview (run before authoring the constitution + overrides)

Skip any question answered by inspecting the repo (`package.json`, lockfiles, config, and
`.claude/kit.config.json`). Ask the rest:

**A. Runtime & framework** — language+version; framework+rendering model; monorepo/single + package manager.
**B. Data & backend** — database + access layer; auth model + role hierarchy; hard domain invariants / common traps.
**C. API & boundaries** — API style (REST/server-actions/tRPC/GraphQL); mandatory request sequence; input validation + where types live.
**D. UI & forms** (skip if backend-only) — component system; styling + tokens; forms + validation lib; i18n locales + default + key location; animation/interaction constraints.
**E. Testing & quality** — test framework + layers (unit/integration/e2e), mocked vs real; quality gate / Definition of Done.
**F. Process** — branch naming/numbering; git auto-commit extension + which hooks; AI integration + context file name.

Convert answers into: **Core Principles** (B5,B6,C8,D14,E16) · **Technology Stack** (A,B,C9,D) ·
**Override docs** (C7/C8→`api-route.md`; E15→`integration-test.md`; D10–13→`feature-module.md`,
or reuse the kit build standard) · **Definition of Done** (E16) · align `init-options.json` /
`extensions.yml` (F17–19).

## 8. Quick start (new project)

```bash
uvx --from git+https://github.com/github/spec-kit.git specify init --here --ai claude --script sh
#   run the Stack Interview (§7) AND the conformance audit (§6) — reconcile any drift first
/speckit-constitution                # writes memory/constitution.md  (after audit + Stack Interview)
#   then author templates/overrides/*.md (use the build standard for feature-module.md) + pre-fill plan-template.md
/speckit-specify  "Add per-user API tokens with rotation"
/speckit-clarify
/speckit-plan
/speckit-tasks
/speckit-analyze
/speckit-implement
```

## 9. Conventions & rules

- **Audit before you author.** Never write a constitution principle the repo's code violates
  (§6 Conformance audit). Reconcile drift first — migrate, amend, or hybrid — then author.
- **Constitution is supreme.** On conflict: constitution → domain docs → build standard. Amend
  (version bump + Sync Impact Report) rather than working around it.
- **One feature = one folder = one branch.** `specs/NNN-feature-name/` + matching branch.
- **Don't skip gates.** Approve the spec before planning, the plan before tasking.
- **Overrides are copy-exactly.** They reproduce the *one* correct pattern, not a variant.
- **Run `/speckit-analyze` before `/speckit-implement`** on anything non-trivial.
- **Keep `init-options.json`, `integration.json`, `extensions.yml` accurate** — source of truth
  for how commands are invoked and what fires around them.
- **Stack changes live in two places only** — the constitution and the overrides.
