# AGENTS.md — driving cckit from an agent

cckit is agent-agnostic. Claude Code is first-class (skills + slash commands), but any agent that
can run a shell can drive the full lifecycle. This file is the contract: the agnostic core. The
per-agent adapters are described in [the Adapters page](docs-site/src/content/docs/adapters.mdx).

## Ground rules

- **Read state before acting.** `cckit status --board --json` returns the board as one JSON object. Decide from data.
- **One issue = one branch = one worktree = one PR.** `cckit start <issue>` creates the isolated
  worktree; do all work there; `cckit pr <issue>` opens the PR. Never commit to the base branch.
  **The effort flow is the one exception, and it is deliberate:** an effort is *1 parent issue = 1
  `effort/<N>` branch = 1 PR* covering **N sub-issues**. Sequential sub-issues commit straight onto
  `effort/<N>` (one commit per sub-issue — that commit's diff is the sub's patch); parallel ones get
  their own file-disjoint `sub/<N><letter>` worktree and merge back into `effort/<N>`. Either way
  exactly one PR opens, from `effort/<N>` — never one per sub-issue. That PR merges with
  `cckit effort close <N>`: `cckit merge` refuses an `effort/*` head, because its squash skips the
  per-sub trace snapshot (`KIT_FORCE=1` merges anyway, with a warning). Full spec:
  `.claude/rules/effort-model.md`.
- **Structured output, TOON-first.** Append `--json` to any verb for machine-readable output. List
  reads (next, plan, wave) come back as **TOON** (token-cheap), the board (`status --board`) as one JSON document; single-result action verbs
  (start, pr, close) return one JSON object. Human (pretty) output is the default; agents prefer `--json`.
- **Idempotent + safe.** Re-running a verb on an already-done step is a no-op, not an error.
- **Never invent paths or config.** Everything resolves from `cckit.config.json`.
- **Hand off when you stop with unfinished work.** `cckit handoff "<what's pending, next step, refs>"`
  saves a local resume-here note; bare `cckit` (no verb) prints it so the next session resumes
  exactly where this one stopped.
- **Run durable prose through `concrete` before writing it.** Every durable artifact — a commit
  message, a PR or issue body, a rule, an ADR, a knowledge doc — goes through
  `.claude/skills/concrete/SKILL.md`: cut only by named offense, never by length;
  evidence, commands, paths and numbers are untouchable; `O13` unverifiable claim and `O14` undecided
  decision are fixed at the gap, not reworded. `cckit brief <issue>` emits this instruction in its
  `## Durable prose` section, so a delegated agent gets it without being told twice.

## Which skill does what

One row per skill; its tasks and terms are its entries in `kit/skills/routing.yaml` (the machine-readable
copy; `bash lib/core/terms-check.sh` names a drift between the two). A term is a file under
`ontology/terms/`; `none` says the skill serves the kit's own setup and no process term yet.

| What you want | Skill | Term |
| --- | --- | --- |
| know where we are: local undone work, PRs waiting, cleanup | `kit-status` | Report |
| read the board by role, see what is blocked | `kit-task-sync` | Sync |
| pick up the next unblocked issue · fan the unblocked wave out to builders | `kit-next` | Task, Wave |
| decide what to build next from what the kit already does | `kit-plan-next` | Effort |
| run an approved plan unattended, waves merged as they go | `kit-autopilot` | Captain |
| create or plan an effort: grill, plan, orchestrate, review, close | `kit-advisor` | Advisor |
| track a new piece of work as an issue | `kit-task-new` | Task |
| start work on an issue in its own worktree | `kit-task-start` | Worktree |
| open the PR for an issue | `kit-task-pr` | Task |
| land an issue's PR once the gate is green | `kit-task-pr-merge` | Gate |
| open and land the PR in one step | `kit-task-pr-auto` | Task |
| close an issue whose PR merged | `kit-task-close` | Task |
| take one issue from code to merged | `kit-ship` | Task |
| scope a goal into an effort · record the deliverables as sub-issues | `kit-effort-new` | Effort, SubIssue |
| start building an effort | `kit-effort-start` | Effort |
| open the one PR of an effort | `kit-effort-pr` | Effort |
| land and close an effort | `kit-effort-close` | Effort |
| see which branches and worktrees can go | `kit-gc` | Worktree |
| delete the merged branches and worktrees | `kit-cleanup` | Worktree |
| audit the project for security findings | `kit-security-sweep` | Check |
| audit the UI's flows, consistency and accessibility | `kit-ux-audit` | Check |
| give visual feedback on a running UI and triage it | `kit-annotate` | Check |
| set cckit up on a new machine | `kit-onboard` | none |
| add an integration or a module to the project | `kit-add` | none |
| add or edit an agent or a skill in a project | `kit-customize` | none |
| send a change upstream to cckit | `kit-contribute` | none |
| change cckit itself and test it live | `kit-dev` | none |
| write a docs page in the house voice | `kit-docs-writer` | none |
| shorten a long input before reading it | `kit-digest` | none |
| show a plan, a decision or a grilling round as a page | `kit-page` | none |

`.claude/skills/` and `.claude/rules/` here are the subset of `kit/templates/` cckit applies to its own
work (`concrete`, `karpathy-guidelines`, and the rules). No agents are installed: this file plus
`cckit brief` is the delegation contract. `lib/core/self-install-test.sh` holds the manifest and every
skip reason, and fails when an installed copy drifts; edit template and copy in the same commit.

## Where the rest lives

Read the file for the task at hand; none of these loads by itself.

| Task | Read |
| --- | --- |
| Run or change a verb: flags, behaviour, lifecycle ops, orchestration and night mode | `lib/verbs/PROMPTS.md` § Core verbs |
| The model endpoint and agent profiles | `lib/verbs/PROMPTS.md` § Model endpoint |
| Edit the docs site: tracks, areas, page frontmatter, redirects | `docs-site/PROMPTS.md` § Editing the docs site |
| The dispatcher, `bin/cckit` | `bin/PROMPTS.md` |
| Library layers and their checks | `lib/PROMPTS.md` |
| The kit payload (`kit/`) | `kit/PROMPTS.md` |
| The forwarding stubs under `scripts/` | `scripts/PROMPTS.md` |
| A prompt to paste into an agent that drives cckit | [the Agents page](docs-site/src/content/docs/agents.mdx#paste-ready-agent-prompt) |
| Effort, branch, merge and close rules | `.claude/rules/` |
