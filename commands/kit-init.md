---
description: Scaffold a tailored .claude/ (agents + skills + rules + workflow) into the current project from a claude-kit role profile.
argument-hint: "[profile] [--name ...] [--repo owner/repo] [--project-number N] [--memory on]"
allowed-tools: Bash, Read, AskUserQuestion, Edit
---

# /kit-init — scaffold this project's .claude/ from claude-kit

You are initializing the current project with the **claude-kit** setup. The kit lives at
`${CLAUDE_PLUGIN_ROOT}` (the installed plugin root). The engine is
`${CLAUDE_PLUGIN_ROOT}/scripts/init.sh`.

## Steps

1. **Identify the project, then gather inputs.**

   **First, identify what you're initializing and recommend the per-project model:**
   - Inspect the target. If it looks like a **parent/workspace** holding several projects (multiple
     subdirectories with their own `.git` / `package.json` / `pyproject.toml` / `Cargo.toml` / `go.mod`),
     **recommend running `/kit-init` inside each project separately** — one `.claude/` per project —
     instead of once at the workspace root. Explain the payoff: each project maps to its own MemPalace
     **wing**, so the kit keeps **traceability and history per project** (decisions, plans, and agent
     diaries never bleed across projects). List the projects you detected and let the user pick.
   - If it's a single project (a `.git` here, or one app), continue here.
   - Suggest a layout that favors the kit — `CLAUDE.md` + `.claude/` at the project root, plans under
     `docs/plans/`, the kit's `scripts/` alongside; **one repo = one kit setup**. See
     [cckit init reference → What the kit writes](https://cckit.dev/init-reference/#what-the-kit-writes).

   **Then gather inputs.** If `$ARGUMENTS` already names a profile and the key values, use them.
   Otherwise ask the user with `AskUserQuestion`:
   - **Profile** — `software`, `content`, `marketing`, `research`, `automation`, or `minimal`
     (read `${CLAUDE_PLUGIN_ROOT}/profiles/*.json` to describe each)
   - **GitHub repo** — `owner/repo` (offer `gh api user --jq .login` as the default owner)
   - **Projects v2 board** — board number if they use one, else "off"
   - **MemPalace memory** — on/off (off unless they actively use MemPalace)
   - **Spec Kit (SDD)** — on/off; pass `--speckit on` to enable the spec-driven workflow section
   - **Pre-push gate** — optional. If they want a check to run before every `git push` (e.g.
     `pnpm build`, `pnpm typecheck`, `pnpm -w lint`), pass `--prepush "<command>"`. Omit for none —
     projects without it are never blocked.
   - **Language** — working language (e.g. English, Spanish, mixed)

   Note: stack-gated build skills (`feature-build-refine`, `supabase-patterns`, …) ship with the
   `software` profile and **self-activate** only when their technology is in the project's
   `package.json` — nothing to choose at init.

   Skip questions already answered in `$ARGUMENTS`. Derive defaults (project name =
   repo name, slug = lowercased name) and only confirm the non-obvious ones.

2. **Run the engine** from the project root:

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/init.sh" \
     --profile <profile> \
     --target "$PWD" \
     --name "<Project Name>" \
     --repo "<owner/repo>" \
     [--project-number <N>] \
     [--memory on] \
     [--lang "<language>"] \
     [--adapter <claude|codex|both>]
   ```

   `--adapter` selects the agent adapter(s), default `claude`. `codex` writes `AGENTS.md` and
   `.agents/{skills,rules}` from the same templates; `both` writes both trees. The selection is stored
   as `adapters` in the config.

   It substitutes `{{VARS}}`, resolves `<!-- IF:FLAG -->` blocks, and writes `CLAUDE.md`,
   `.claude/{kit.config.json,agents,skills,rules,settings.local.json}`, and `scripts/`.

   Tip: add `--dry-run` to print the exact scaffold plan (files, hooks, onboarding tools) **without
   writing anything** — useful to confirm the profile first. Offer the user a dry-run preview if the
   profile/target is uncertain.

3. **Set up external tools — opt-in.** Configure the CLIs the scaffold relies on. For each tool,
   **explain what it is and why it's needed, then install/authenticate only with the user's
   go-ahead**. A declined tool leaves the matching features dormant (they don't error) and can be
   re-run anytime.

   **GitHub CLI (`gh`)** — backs the whole task/PR workflow (issues, PRs, labels, milestones).
   - Detect: `gh auth status`. If not authenticated, explain every `task-*` skill needs it and,
     with consent, run `gh auth login`. Re-check with `gh auth status`.

   **MemPalace** (only when memory was enabled) — the persistent-memory backend: an MCP server
   exposing the `mempalace_*` tools plus the `mempalace-mcp` binary, which the `Stop`/`PreCompact`
   hooks and every agent's diary protocol depend on. Absent = dormant, never errors.
   - Detect: `command -v mempalace-mcp` and `claude mcp list | grep -i mempalace`.
   - Binary present but unregistered → with consent run `claude mcp add mempalace mempalace-mcp`;
     verify with `claude mcp list`. Then confirm with a `mempalace_status` call.
   - Binary missing → explain it and ask the user for their install method; `mempalace-mcp` is a
     user-provided tool, so **do not guess a package name or fabricate an installer**. Re-check
     `command -v mempalace-mcp`.

   **Google Workspace CLI (`gws`)** — opt-in; offer only if the user works with Google Docs / Sheets /
   Slides / Drive / Gmail / Calendar (e.g. the `gws-slides` skill drives it).
   - Detect: `command -v gws`, then `gws auth status`.
   - Installed but not authenticated → with consent run `gws auth login` (OAuth, opens a browser).
     `gws auth setup` configures the GCP project + OAuth client and needs `gcloud`. Re-check
     `gws auth status`.
   - `gws` missing → explain it and ask the user for their install method; **do not guess a package
     name or installer**. Re-check `command -v gws`.

4. **Report** what was written (echo the engine's summary) and its closing lines.

5. **Git and GitHub setup.** The engine does this itself: `git init` + first commit, one commit
   holding the kit files on the base branch when the repository already had commits, the GitHub
   repository (private unless `--public`), the base branch `develop` (pushed with that commit),
   labels, milestones, delete-head-branches, base-branch protection, Projects v2 ids, the doctor
   report. You have no terminal, so it runs only with `--yes`, and the scaffold in step 2 ends
   with "Git and GitHub setup: not run" followed by one "Not done:" block per thing left undone
   (the kit files are not committed; the base branch does not exist). Relay those blocks: until
   the kit files are committed, a task started in the project gets a folder without them. Show
   the user the plan first, then run it on their go-ahead:

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/init.sh" --target "$PWD" --dry-run   # the steps, nothing written
   "${CLAUDE_PLUGIN_ROOT}/scripts/init.sh" --target "$PWD" --yes       # run them; finished steps are skipped
   ```

   Each step prints `done`, `skipped` or `failed`; relay the failed ones with their reason. Pass
   `--no-github` in step 2 when the user wants the files only. Creating a repository and changing
   branch protection are outward-facing: never pass `--yes` without the user's go-ahead.

   **A new project.** When the target is an empty folder, a folder with no project in it, or the
   user's home directory, ask the engine's questions with `AskUserQuestion` (is this a new project,
   its name and folder, the recipe from `${CLAUDE_PLUGIN_ROOT}/recipes/*.json`, whether it needs a
   database and which one from `${CLAUDE_PLUGIN_ROOT}/databases/*.json`; each descriptor marks the
   recommended one), write the answers to a JSON file and pass `--answers <file>`. Keys:
   `new_project`, `folder_use`, `project_name`, `location`, `recipe`, `database_needed`, `database`,
   `profile`. Never scaffold into a home directory. For a database, the engine prints the steps to get
   the credentials; the user types the values into the env file — do not ask for them in chat and do
   not write them yourself.

6. **Audit stack conformance** (when the `software` profile activated a stack-gated build skill).
   The build skills (`feature-build-refine`, `supabase-patterns`, …) self-activate from
   `package.json` and immediately become the project's "how we build" standard — but the existing
   code may not follow them. Briefly audit the repo against each activated skill (directory layout,
   the canonical form/handler/data-access patterns) and report **conforms / partial / divergent**.
   On non-trivial drift, surface the reconciliation choice to the user — **migrate repo → standard**,
   **amend standard → repo**, or **hybrid** — and, if they choose migrate/hybrid, offer a phased
   migration plan (`docs/plans`, per the `plan-output-format` rule) + tracked issues. Don't present
   the standard as already-followed when it isn't. (Spec Kit's `/speckit` runs the deeper version of
   this audit in its §6 before authoring the constitution.)

7. **Point to `/kit-customize`.** Tell the user they can tailor the setup anytime with `/kit-customize`
   — add/edit/delete agents, wire skills + tools onto them, search/suggest skills for the profile, lint
   agents, or build (and save) a custom profile. It also activates automatically when they ask to
   create/edit/delete an agent. Use it whenever the presets don't fit exactly. And point them to
   **`/kit-docs`** to browse the kit's guides (usage · agents · reference · contributing) from inside
   Claude Code. For a React project, point them to **`/kit-annotate`** to add click-to-annotate UI
   feedback wired to Claude (via Agentation).

## Rules

- Never overwrite an existing `.claude/kit.config.json` without passing `--force` and confirming.
- Do not invent a repo or owner — confirm with the user.
- After scaffolding, the project owns its `.claude/` files. Edits there are the user's, not the kit's.
