# AGENTS.md — driving cckit from an agent

cckit is agent-agnostic. Claude Code is first-class (skills + slash commands), but any agent that
can run a shell can drive the full lifecycle. This file is the contract.

The two-layer split — an agnostic core (this contract) and per-agent adapters (Claude Code is
adapter one) — is described in [the Adapters page](docs-site/src/content/docs/adapters.md).

## Ground rules

- **Read state before acting.** `cckit sync --llm` returns the board as TOON. Decide from data.
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
- **Structured output, TOON-first.** Append `--llm` to any verb for machine-readable output. List
  reads (sync, next, plan, wave) come back as **TOON** (token-cheap); single-result action verbs
  (start, pr, close) return one JSON object. Human (pretty) output is the default; agents prefer `--llm`.
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

## What cckit installs for itself

`templates/` is what `cckit init` writes into a consuming project. `.claude/skills/` and
`.claude/rules/` in this repo are the subset cckit applies to its **own** work — `concrete`,
`karpathy-guidelines`, and the rules for branches, efforts, PR titles, delegation, communication
style and issue lifecycle (`issue-lifecycle.md`: sub-issues not checkboxes, approved-plan autonomy,
explicit closes) and merge safety (`merge-safety.md`: current base before merging, a coupled chain as
one PR, the gate re-run on the integration branch) and authoring (`authoring.md`: docs in the same change,
no issue numbers in pasted prompts, summaries without machine flags) and the shared checkout
(`shared-checkout.md`: never move the primary checkout by hand, work in a worktree, call a freshly merged verb from a
current worktree's `bin/cckit`). No agents are installed: this file plus `cckit brief` is the delegation contract here.

The manifest and the reason for every skipped template are in `scripts/self-install-test.sh`, which
also fails if an installed copy drifts from its template. Edit a template and its installed copy in
the same commit.

## Core verbs

| Verb | Purpose | LLM mode |
| --- | --- | --- |
| `cckit init [--adapter <claude\|codex\|both>]` | scaffold config + the selected adapter(s), default `claude`. `claude` writes `CLAUDE.md` + `.claude/`; `codex` writes `AGENTS.md` + `.agents/{skills,rules}` and, when it is the only adapter, keeps the config at the root `cckit.config.json` and the ownership manifest at `.cckit/kit.manifest.json` — no `.claude/` tree. The selection is stored as `adapters` in the config; `--upgrade` keeps it, and `--upgrade --adapter <name>` adds an adapter without rewriting the other's files. Both adapters get the same hook scripts — base-branch commit guard, raw-git guard, session mail, session-start checks: Claude in `.claude/hooks/` (mail wired in the tracked `.claude/settings.json`), Codex in `.codex/hooks/`, registered in `.codex/hooks.json` by a merge that keeps the entries already there and uses no absolute path. Codex runs a project hook only after it is trusted (`/hooks`). Specialist agents come from one role source (`templates/agents/<role>.md`): Claude gets `.claude/agents/<role>/AGENT.md`, Codex gets `.codex/agents/<role>.toml` (`name`, `description`, `developer_instructions`); a Claude tool allowlist and model alias do not translate and are written into the TOML as comments. Not installed for Codex: memory hooks (they read Claude Code transcripts) | — |
| `cckit sync` | board state / what's unblocked | `--llm` → TOON |
| `cckit sync --json` | the board as ONE JSON object for a dashboard: per-role issues, `unassigned`, `blocked`, `stale`, `mergeQueue` (merge order). `--write` saves it atomically to `<git-common-dir>/kit-sync-cache.json` and never overwrites it with a failed or partial fetch; `--cached [TTL]` prints that cache with no `gh` call while it is younger than TTL seconds (default 60), else refreshes it; `--watch [SECS]` refreshes every SECS (default 30) and keeps the last good cache when a fetch fails; `--plan` inlines `effort plan`. Each fetch emits `op.start` / `op.done` (op `sync`) to `kit-events.jsonl`. `--write` / `--cached` / `--watch` refuse `--role` / `--milestone` (exit 2) | `--json` → JSON (`--llm` / `--output=json` stay TOON) |
| `cckit next` | the next unblocked issue + how to start it. Human output ends with the weekly cadence line (Monday `cckit plan` · daily `cckit next` · Friday `cckit gc`); the TOON rows stay `{number,ctx,title}` | `--llm` → TOON |
| `cckit plan` | wave plan: deps-ordered, priority-sorted within a wave, file-disjoint, session-fit | `--llm` → TOON |
| `cckit plan-next` | forward plan: inventory current skills/verbs/rules/docs → propose what to build next | `--llm` → TOON |
| `cckit status` | where are we: the next effort that can start in each flow (no open blocker; p0 → p3, then lowest number), local undone work, open PRs waiting on a human, cleanup available (local + remote), then one line with the resident instruction-file bytes (`CLAUDE.md` + rules without `paths:`) against the 150k limit and the three largest files | `--llm` → JSON (`next_efforts` is one row per flow; `null` when the efforts could not be read) (`instruction_budget`, `null` when nothing was measured) |
| `cckit brief <issue>` | the delegation brief for an issue, from real state: worktree, seed freshness, owned files, the helpers they sit on, standing gotchas | — |
| `cckit wave [--adapter <claude\|codex\|both>]` | read open efforts, propose incoming waves: fan-out brief + captain drive. The wave data (issues, ctx, one runtime-neutral prompt per issue) is the same for every runtime; the dispatch wording is per adapter — Claude Code spawns Task subagents with worktree isolation, Codex is told to launch `cckit orchestrate --agent codex`, because cckit creates the worktrees there. Default: the project's stored `adapters` (`CCKIT_ADAPTER` overrides) | `--llm` → TOON (wave data only, identical for both adapters) |
| `cckit watch [--merge] [--loop]` | captain: gate open PRs, squash-merge CLEAN, advance the wave | — |
| `cckit qa <up\|ready\|open\|stop\|verdict> [--lane N]` | the QA lane, one review stack per lane (a lane is an issue number: the current branch's, or `--lane`). `up` launches the command declared under `qa` with the project's port env vars set to this lane's block and exits 0 only once every `qa.readiness` probe answers 2xx/3xx (`ready` waits on a launched lane; rc 1 names the failing probes and the launch log, rc 2 refuses a config problem, or a lane port another process already listens on, before launching). `open` prints and opens the changed screen — the PR body's `QA route: /path` line, else `qa.route` — and refuses a lane that is not usable. `stop` exits 0 only when nothing listens on the lane's ports; a listener the lane did not launch is left running (rc 1) unless `--force`. `verdict <pass\|fail>` writes a `qa` receipt bound to the reviewed commit, upserts one PR comment and mails a fail's notes to the builder; with no `pass\|fail` it reads back `pass` · `fail` · `stale` · `none`, exit 0 only for a pass on the current head. `captain.mergePolicy.requireQa` makes `cckit watch` hold a PR without that pass (`QA_MISSING`); a fail on the current head always blocks (`QA_FAILING`) | `--llm` → JSON |
| `cckit start <issue> [slug]` | isolated worktree + branch, bootstrapped: env files copied, per-worktree dev PORT, deps installed at the selected targets. Precedence: **`worktree.installPaths` if set** (those dirs only, installed whether or not each declares dependencies — `[]` installs nothing, and the root/workspace checks are skipped entirely), **else** the root *only when* its manifest declares dependencies or it is a workspace root **with at least one member** (a non-empty `packages:` list, or a non-empty `workspaces` / `workspaces.packages` array), **else nothing** — so a dependency-free root never gets a stray empty `pnpm-lock.yaml`. `installPaths` entries that escape the worktree are refused. `KIT_WT_INSTALL=0` skips the install. **Claim-checked:** `cckit start [--force] <issue>` refuses (rc 1) when another live session already holds the issue's claim in `<git-common-dir>/kit-sessions/` — before the issue read, the fetch and `git worktree add`, so a refusal makes no branch and no worktree. `--force` / `KIT_FORCE=1` starts anyway and takes the claim; a claim whose session pid is dead is reaped; re-running from the same session or from inside the claimed worktree is the usual no-op. A board Status of In Progress or In Review only warns | `--llm` |
| `cckit pr <issue> <summary> [--base <branch>]` | commit + push + open PR. `--base` targets a branch other than the configured base (`.github.baseBranch`) — a release PR `develop` → `main`, or a hotfix to the release branch; labels, milestone, board and `Closes #N` are unchanged. The push exports the target as `KIT_PR_BASE` (set with or without `--base`), so a git pre-push hook can compare against the branch the PR targets. `--base` with no value exits 2 before the commit and the push | `--llm` |
| `cckit hotfix <pr\|sha> [--base <branch>]` | carry ONE merged change to the release branch (`main` unless `--base` or `KIT_HOTFIX_BASE`): worktree `fix/<N>-hotfix-<base>` from `origin/<base>`, `git cherry-pick -x` (`-m 1` for a merge commit; every commit of a rebase-merged PR, oldest first), push with `KIT_PR_BASE=<base>`, PR titled after the source with `Cherry-pick of #N` in the body and no `Closes`. A digits-only source is a PR number and must be MERGED; anything else is a commit, whose PR number is read from a `(#N)` suffix or `Merge pull request #N`. Re-runnable: a picked commit is not picked twice and an open PR is reported, not re-created. A conflict stops before the push — resolve, `git cherry-pick --continue`, re-run | `--llm` → JSON (`ok`, `url`, `worktree`, `detail`; a refusal is `ok:false` with the reason in `detail`) |
| `cckit close <issue> <summary>` | close issue + mark done | `--llm` |
| `cckit claims` | list the live session claims `cckit start` wrote: issue, session pid, start time, branch, worktree. Read-only — a dead session's claim is hidden here and reaped by the next `cckit start` on that issue | `--llm` → JSON array |
| `cckit effort new "<name>" ["sub :: desc" …]` | parent (4-section body + ctx/kind/priority/role/flow labels) + linted native sub-issues — identical to `/kit-effort-new` (one shared core); `start`/`pr`/`close` take `<slug\|N>` | flags: `--flow/--role/--kind/--priority/--goal/--scope/--for-agents/--verification/--depends-on/--milestone`, `--slug`. `--kind` is one of `feat fix task chore security scaffold ci adr spike plan` (default `task`); any other value is refused before anything is created |
| `cckit effort chain <a> <b> [<c> …]` | wire 2+ issues into a linear order: `b` `blocked_by` `a`, `c` `blocked_by` `b`, plus a `- Depends on #<predecessor>` line in each successor's `## Relations` section. These are the edges `cckit plan` layers into waves. Idempotent (an edge or line already there is skipped); pre-existing blockers are kept, never replaced. Validates everything first — fewer than two numbers, a non-numeric arg, an issue that does not exist, a repeated number, or an edge that would close a cycle refuses the whole chain and writes nothing | — |
| `cckit effort start [--force] <slug\|N> [slug]` | effort branch + bootstrapped worktree, **WIP-limited**: refuses a NEW effort once `effort.wipLimit` (default 2) are already in progress. In progress = an `effort/<N>-<slug>` branch exists as a local head **or** on origin, read with `git ls-remote` rather than the cached `refs/remotes` (which is wrong both ways: it misses a branch pushed since the last fetch and keeps one deleted on origin until a prune). At the limit refuses; only strictly under it starts. Re-starting an effort that is already in progress is never gated. The check runs before the fetch/branch/worktree/bootstrap, so a refusal makes no branch, no worktree and no board change — it is not read-free (it queries origin, and a `<slug>` arg was resolved first, which can run `gh issue list`). `0` refuses every ordinary start; `--force` still starts. A non-integer value is ignored with a warning and the default 2 is used; `EFFORT_WIP_LIMIT` overrides the config per invocation. `EFFORT_WIP_REMOTE=0` — or an unreachable origin, which warns and proceeds — counts the cached refs instead. With no `[slug]`, a failed read of the issue title warns on stderr and the start continues with the effort's existing branch slug, or `effort`. Does **not** gate `cckit start <issue>` | `--force`, or `KIT_FORCE=1` |
| `cckit effort pr [<slug\|N>]` | the ONE effort PR, titled as a Conventional Commit subject carrying the effort id: `type(scope): name [#N]` (scope = the `flow:` label, else the title's `[Flow]` tag; type = `--type`, else the `kind:` label, default `feat`). Refuses before any `gh` call when the title lacks `[#N]` or fails `commitlint_check`. `pr.titleStyle: issue-title` gives `[Role] [#N] name` with no commitlint check | flags: `--summary[-file]`, `--for-agents[-file]`, `--title`, `--type` |
| `cckit effort plan` | session-fit effort plan. Rows come from GitHub (one listing + one `blocked_by` call per effort), or from the executable named by `effort.planSource` (`EFFORT_PLAN_SOURCE` overrides), called as `<source> <owner/repo>` from the project root and printing `number<TAB>flow<TAB>ctx<TAB>title[<TAB>blockers]` rows plus an optional `# age: <text>` line. A source that is not executable, exits non-zero or prints no rows falls back to GitHub. The `source:` line under the header names the source used, its age when reported, and any fallback | `--llm` → JSON |
| `cckit orchestrate <a> <b> …` | run N flows in parallel worktrees, in tmux or Herdr. cckit owns the worktree per issue, the `blocked_by` gate, the `--cap` and the result: on tmux each pane runs the agent under `scripts/wave-worker.sh`, which records how the process ended | — (use `--dry-run`) |
| `cckit orchestrate --results [--session=<s>] [--wait <secs>]` | read the wave's collected results: `success` (exit 0), `failure` (exit 1–128), `interrupted` (signal exit, or a `running` record whose pid is gone on the host that wrote it); not finished: `launched`, `running`; `untracked` on Herdr, which owns the agent process. rc 0 all success · 1 any failure/interrupted or no records · 3 none failed, some unfinished. Same for every `--agent` kind | `--llm` → JSON |
| `cckit autopilot [<a> …]` | select work, then call `orchestrate --detach` under a cap | — (use `--dry-run`) |
| `cckit autopilot run [<issue>] --objective "<text>"` | ONE headless objective on the current branch: `claude -p` or `codex exec`, one round at a time. Code stops it on `--max-iters` (default 5), `--max-seconds` (3600), `--round-seconds` (900), a passing `--until "<cmd>"`, a failing `--check "<cmd>"` gate, or a round that changed neither HEAD nor the tree. `--max-tokens` is checked between rounds from the runtime's own usage output; a round that prints none stops the run. `--publish --summary "<s>"` opens the PR through `cckit pr` unless the branch already has one. `--resume` continues with counters carried over; a round cut short by a signal or a killed runner counts as usage `unknown`, not zero, and a start is refused (exit 2) while the agent an earlier run recorded in `.cckit/autopilot/<branch>.agent.pid` is still alive. Exit 0 done · 2 refused · 3 agent failed · 4 limit · 5 no progress · 6 gate failed · 7 publish failed · 130 interrupted. Refuses the base branch, `--notify`, and an agent other than claude/codex. Never merges | state file `.cckit/autopilot/<branch>.json` (use `--dry-run`) |
| `cckit gc` | report prunable branches + worktrees — SAFE (own PR merged) and LANDED (no PR of its own, work already on base: effort subs, `worktree-agent-*` isolation worktrees) — never one whose issue is still open; aborts if the protection helper is missing. A branch whose PR or issue state could not be read (a failed `gh` call) is reported UNKNOWN ("could not determine") and kept, never "no PR". A worktree with a detached HEAD gets its own row: LANDED when it is clean and its HEAD is on the base branch or `main`, ORPHAN otherwise | `--llm` → JSON counts (`safe`, `landed`, `protected`, `orphan`, `unknown`) |
| `cckit cleanup [--yes]` | the guided destructive sweep over that report: plan first, delete only the SAFE + LANDED rows and prune the listed ZOMBIE metadata (staged work recovered to its branch first); ORPHAN / PROTECTED / UNKNOWN / stashes are never deletable. A LANDED detached worktree is removed; an ORPHAN one, and a detached zombie still holding staged work, are kept | `--llm` → JSON counts + `applied` |
| `cckit render` | stdin markdown → rich (glow on a TTY; verbatim when piped) | — |
| `cckit version` | the installed cckit version | `--llm` |

Every verb accepts a global `--llm` (alias `--output=json`); verbs that produce a result emit a
single JSON object/array on stdout, with human text on stderr. Interactive/launch verbs
(`init`, `orchestrate`, `autopilot`) have no JSON result — use `--dry-run` to inspect their plan.
`cckit brief` has no JSON form either, and deliberately: its output IS the prompt you hand a
delegated agent, so markdown is the machine-readable form. Read the facts behind it as data with
`cckit lib --llm` and `cckit status --llm`.

> **`cckit plan-next` is the one exception to "feed verb output back to the model."** Its forward
> plan is for the human/orchestrator's decision only — never inject it into a monitored model's
> prompt or context (context-anxiety rule). Run it, decide, and hand only the chosen, scoped effort
> to an agent. `cckit plan` / `cckit next` (ordering existing work) remain safe to reason over.

### Lifecycle ops (so autopilot runs unattended)

Every operation an unattended run needs is reachable through the one CLI:

| Verb | Purpose |
| --- | --- |
| `cckit scan` | detect the repo's stack + kit state (emits JSON) |
| `cckit doctor [--fix]` | onboarding preflight (deps, gh auth); asks before installing on a TTY, `--fix` skips the prompt. Reports the CLI of each selected adapter (`claude`, `codex`) present or absent; `cckit doctor --agents` prints only those rows, makes no network call, and exits 1 when one is absent. With `codex` selected it also reports whether the hooks are registered in `.codex/hooks.json` (a warning when not; whether Codex trusts them is not readable). One row per `integrations/` descriptor whose config key is on, installed by the shared runner; an integration installs only after `--fix` or a yes at the prompt (recorded as `install:<id>` in `.cckit/consent`) — a run with no TTY and no `--fix` reports it missing, installs nothing and exits 1. Also prints the resident instruction-file line `cckit status` prints, and warns when it is over the 150k limit |
| `cckit add [<name>] [--set k=v] [--answers FILE] [--dir DIR]` | no name: list every integration descriptor in `integrations/` plus the modules, exit 0 (`--llm` → one JSON object with `enabled` and `applies` per integration). With an integration: set the one config key its descriptor names, in the config `kit_config_path` resolves — no other key changes, and nothing is installed. A descriptor that lists `rules` (`graft` → `code-retrieval`) also gets each one copied into `.claude/rules/`; an existing rule file is kept. Declines (exit 0, nothing written) on a repo with no file the integration can work on; exits 1 with no project config or an invalid descriptor. With a module (`software`): write this directory's `.claude/kit.config.json`. `KIT_DRY_RUN=1` writes nothing, and for an integration prints the install candidates in order plus the wire command. The tools, the consent line and the install order: [Integrations](https://cckit.dev/integrations/) |
| `cckit update` | report whether the project is behind the installed cckit |
| `cckit migrate` | reshuffle an old kit layout to the current one |
| `cckit digest <path\|url>` | summarize one file or URL with the local model (exit 2 when the local model server is down) |
| `cckit release <ver>` | cut a release — **dry-run by default**, `--publish` to act |

### Orchestration flags (`orchestrate` / `autopilot`)

| Flag | Effect |
| --- | --- |
| `--dry-run` | resolve + print the launch plan; create no worktrees, start nothing |
| `--cap <N>` | concurrency cap (default 4); flows past the cap are queued + reported |
| `--agent <cmd>` | per-pane agent command (default `claude`, or `CCKIT_AGENT=`) — drive any CLI agent |
| `--profile <name>` | run a declared agent profile (or `CCKIT_PROFILE=`): its `kind` becomes the agent and its `args` are passed to the CLI. Unset picks the cheapest-tier profile; `--agent` overrides and skips profiles entirely. A project that declares none is unaffected |
| `--runtime <tmux\|herdr>` | terminal owner (default `tmux`, or `CCKIT_RUNTIME=`); Herdr requires a supported agent kind such as `codex` or `claude` |
| `--force` | launch even if an issue is `blocked_by` an OPEN issue (the gate is on by default) |
| `--no-seed` | start the agent without an auto-prompt |

**Base branch override.** `KIT_BASE_BRANCH` in the environment wins over `github.baseBranch` in the
config for that invocation: `KIT_BASE_BRANCH=effort/<N>-<slug> cckit orchestrate <sub>` cuts the
sub's worktree from the effort branch instead of the base. `orchestrate` then prints
`base '<branch>' comes from KIT_BASE_BRANCH in the environment (the config says '<base>')`. The
branch must exist on origin (`wt_start` fetches it). Every verb that loads the config reads the same
variable — `cckit start` cuts from it and `cckit pr` targets it — so set it per command, not with a
shell-wide `export`. `orchestrate` passes an override on to each agent pane (tmux: `env KIT_BASE_BRANCH=…`
on the agent's command line; Herdr: `--env`), so `cckit pr` in the pane targets the branch the
worktree was cut from. The base cckit resolved from a config is not an override in a child process:
a `cckit` run in another project reads its own config.

### Night mode (no verb: `/kit-autopilot` + two scripts)

Night mode has no `cckit` verb. The `kit-autopilot` skill reads the owner's night grant with
`scripts/night-grant.sh read <parent>` and launches the Workflow script `scripts/night-run.mjs`
with the args that prints. In a consuming project both live under `${CLAUDE_PLUGIN_ROOT}/scripts/`.

| Rule | What the scripts enforce |
| --- | --- |
| Who may grant | a `<!-- night-grant -->` comment counts only from an author GitHub reports as `OWNER`, from `github.owner`, or from a login in `night.grantors`; any other author's is ignored |
| Approval | the grant's `waves` list; no label or body section on the effort is required |
| Width | `effort.wipLimit` efforts at once (default 2), never more than 4; executors never pass `--force` |
| Wave order | a wave that did not fully merge ends the run `blocked`; no later wave starts |
| Final check | the gate on the base branch, even when the grant sets a `stopCommand` |
| Waivers | each must equal one floor name; `workflows`, `cost`, `secret` and `night.neverWaivable` are never waivable |

Config: `night.floors`, `night.neverWaivable`, `night.gate`, `night.grantors`, `night.refuseLabels`
— see [Night mode](https://cckit.dev/config-and-permissions/#night-mode).

## The agent loop (reference)

1. `cckit sync --llm` → pick an unblocked issue.
2. `cckit start <issue>` → enter the worktree it prints.
3. Implement; commit early and often.
4. `cckit pr <issue> "<summary>"` → open the PR; report the URL.
5. Stop. Merging is a human/captain decision unless an approved plan says otherwise.

## Model endpoint

cckit shells out to whatever agent invokes it; it does not embed a model. For verbs that synthesize
text (digests, ingest), the model endpoint is configurable via environment — see the docs site (
[cckit.dev](https://cckit.dev).

The effort-close judge reads an OpenAI-compatible endpoint from `CCKIT_MODEL_URL` (base URL; it
POSTs to `<value>/chat/completions`), `CCKIT_MODEL` (model name) and `CCKIT_MODEL_TOKEN` (bearer
token). A project with its own variables names them in the config instead — `model.urlEnv`,
`model.modelEnv`, `model.tokenEnv` hold env var **names**, never values. See
[Model endpoint for the effort judge](https://cckit.dev/config-and-permissions/#model-endpoint-for-the-effort-judge).

**Agent profiles** (`agents.profiles` in the config) carry a spend `tier`, a permission policy and
extra CLI argv. **cckit never names a model** — you spell your own flags in `args`, and the
cheapest-tier profile runs when `agents.default` is unset, so the inexpensive path is the default
by construction. A profile also declares the `stages` it may run at and whether it may
`write` to a branch; a profile with no `stages` is allowed nowhere, and `write` defaults to false.
Validation refuses an undeclared profile, a missing `kind`, an unknown stage, or a dangling
`agents.default` **before** a worktree or pane exists. See
[Agent profiles](https://cckit.dev/config-and-permissions/#agent-profiles).

## Paste-ready agent prompt

Drop this verbatim into your agent's system prompt (or the first message of a session) to make it
operate the repo through cckit. It is self-contained.

```text
You operate this repository through cckit, a CLI that runs the full GitHub work lifecycle.

Operating rules:
1. Read state before acting. Run `cckit sync --llm` and decide from the TOON board it returns
   (TOON is a compact table format — parse it, don't guess the board).
2. One issue = one branch = one worktree = one PR. Begin every task with `cckit start <issue>`,
   then cd into the worktree path it prints. Never commit on main or develop.
3. Append `--llm` to any verb for machine-readable JSON output.
4. Follow this loop: sync -> start <issue> -> implement (commit early and often) ->
   `cckit pr <issue> "<one-line summary>"` -> report the PR URL -> stop.
5. Merging is a human decision. Do not merge unless an approved plan explicitly says you may.
6. Re-running an already-done step is a no-op, not an error. Never invent paths or config:
   everything resolves from cckit.config.json.
7. If a command fails, read its stderr and fix the cause. Do not work around the kit.
```

Copy the fenced block above. Nothing in it is repo-specific, so it works for any project that has
run `cckit init`.
