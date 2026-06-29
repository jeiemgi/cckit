---
name: kit-contribute
description: Contribute your additions and requests back upstream to claude-kit as a GitHub PR (or issue). Use AUTOMATICALLY whenever the user asks to contribute to claude-kit, submit a PR, open a PR upstream, propose a change to the kit, give back to the kit, share my agent / skill / profile with the kit, send or file a feature request, or request a feature. Opens a pull request (or, for a pure idea, an issue) against the kit's upstream repo. Works from a project scaffolded by /kit-init and customized with /kit-customize, but also stands alone.
argument-hint: "[agent <name> | skill <name> | profile <name> | request]"
allowed-tools: Bash, Read, Edit, Write, Glob, Grep, AskUserQuestion, Skill
---

# kit-contribute — give your additions back to claude-kit

You help a **downstream user submit a contribution upstream** to the claude-kit repo as a GitHub
**PR** — a new agent, skill, or profile — or, for a pure idea, a GitHub **issue**. The kit (templates
+ profiles) lives at `${CLAUDE_PLUGIN_ROOT}`; the user's project lives in `./.claude/`. You never push
to the installed plugin dir — you work in a fresh temp clone of the upstream repo.

This is the **inverse of `/kit-customize`**: where customize *parameterizes a template into a project*,
you *de-parameterize a project artifact back into a reusable kit template*.

## 1. Resolve upstream

- The kit ships **inside `jeiemgi/cckit`** at `` — there is no
  standalone `claude-kit` repo. Read `${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json` → `repository`
  for `OWNER/REPO` (default `jeiemgi/cckit`); contributing = a PR to that repo touching
  `**`. **Confirm `OWNER/REPO` with the user.**
- Require GitHub auth: run `gh auth status`. If not logged in, **stop** and tell the user to run
  `gh auth login` first — every step below needs it.

## 2. Pick a contribution type

If `$ARGUMENTS` names one (`agent`, `skill`, `profile`, `request`), use it. Otherwise ask via
`AskUserQuestion`:

| Type                    | What it adds                                  | Target path                              |
| ----------------------- | --------------------------------------------- | ---------------------------------------- |
| **Agent**               | a reusable agent template                     | `templates/agents/<name>.md`             |
| **Skill**               | a `SKILL.md` (scaffolded or plugin)           | `templates/skills/<name>/` or `skills/<name>/` |
| **Profile**             | a preset role profile JSON                    | `profiles/<name>.json`                   |
| **Feature request / idea** | a proposal — GitHub **issue** by default   | (issue) or `requests/<slug>.md`          |

## 3. Assemble the artifact

### Agent — de-parameterize back into a template

Take a project agent `./.claude/agents/<name>/AGENT.md` and **invert kit-customize's substitution**:

| Concrete value in the project agent      | Replace with        |
| ----------------------------------------- | ------------------- |
| the project's name                        | `{{PROJECT_NAME}}`  |
| the working language                      | `{{COMMS_LANG}}`    |
| the project's MemPalace wing              | `{{WING}}`          |
| the project's slug                        | `{{PROJECT_SLUG}}`  |

- **Re-wrap the `## Memory (MemPalace)` section** in `<!-- IF:MEMORY -->…<!-- /IF:MEMORY -->`. If the
  project had memory **off** (no Memory section), **add** the block with the standard MemPalace table
  (wing=`agent-<name>` for diary, `{{WING}}` for shared rooms — match `templates/agents/n8n.md`).
- **Strip anything project-specific or secret** — concrete repo names, hostnames, IDs, tokens,
  credential names. Read `kit.config.json` to know exactly which literals to swap out.
- Keep the frontmatter contract intact (`name` = file basename, `description`, `when_to_use`,
  `tools`, `skills`). Target: `templates/agents/<name>.md`.

### Skill — a SKILL.md

Ask whether it's a **scaffolded skill** (lands in a project's `.claude/skills/` via init) →
`templates/skills/<name>/SKILL.md`, or a **plugin skill** (ships with the plugin itself) →
`skills/<name>/SKILL.md`. Strip project-specific paths/values.

### Profile — a preset JSON

Often the user already saved one via kit-customize at `~/.claude/kit-profiles/<name>.json`. Match the
preset shape exactly (`name`, `label`, `description`, `agents`, `skills`, `rules`, `roles`,
`milestones`, `defaults`) — see `profiles/automation.json`. **Verify every agent it lists exists** as
`templates/agents/<agent>.md` in the upstream clone (step 4) — bundle any missing agent template in
the **same PR**, or drop it from the list. Target: `profiles/<name>.json`.

### Feature request / idea — a proposal

Author a concise proposal with these sections: **Problem · Proposal · Scope · Why**. By default this
goes as a GitHub **issue** (lowest friction — no clone needed). Offer the alternative of a PR that adds
`requests/<slug>.md` with the same content if the user prefers a tracked file.

### Lint before submitting (agent / skill / profile only)

Validate before you ever push. Reuse existing tooling via the `Skill` tool:

- **Agents** → run `claude-kit:kit-customize`'s lint (frontmatter, required keys, name↔file, tools
  shape, skills resolve, **no leftover `{{VAR}}`** except the intended template tokens).
- **Skills** → defer to `agent-skills:skill-crafting`.
- **Profiles** → validate JSON parses + agent references resolve (above).

**Block on hard failures.** Fix or stop; don't submit a broken artifact.

## 4. Determine access & prepare a clone

Check permission: `gh repo view OWNER/REPO --json viewerPermission -q .viewerPermission`.

| Permission                  | Path                                                                       |
| --------------------------- | -------------------------------------------------------------------------- |
| WRITE / MAINTAIN / ADMIN    | clone upstream: `gh repo clone OWNER/REPO <tmp>`; branch `contrib/<type>-<name>` |
| READ / none                 | **fork**: `gh repo fork OWNER/REPO --clone --fork-name claude-kit` into a `<tmp>`; branch off `main` |

- Use a fresh temp dir (e.g. `mktemp -d`). **Never** push from `${CLAUDE_PLUGIN_ROOT}` or the
  marketplace cache — they're managed/detached.
- Never assume push rights to upstream — fork whenever you lack write access.
- Place the assembled artifact (step 3) at its correct path **inside the temp clone**.

## 5. Commit & push

- `git add` the file(s) at the correct kit path.
- Commit with a clear, scoped message: `feat(agent): add <name>`, `feat(skill): add <name>`,
  `feat(profile): add <name>`.
- Push the branch to the fork/origin (`git push -u origin <branch>`).

## 6. Open the PR — confirm first (outward-facing)

**This is public + outward-facing — confirm with the user before opening it.**

- Artifact PR: `gh pr create --repo OWNER/REPO --base main` — from a fork the head is
  `<your-login>:<branch>`. Title summarizes the contribution; body states **what it adds, why, and how
  it was tested/linted**.
- Pure request, no artifact: `gh issue create --repo OWNER/REPO` with the **Problem · Proposal · Scope
  · Why** body instead.
- Print the resulting URL.

## 7. Report

Print the PR/issue URL. Remind the user that a **maintainer reviews before it merges**, and that once
merged they'll receive it via `claude plugin update`.

## Rules

- Always go through a PR or issue — **never push to upstream `main`**.
- Fork when you lack write access; work in a temp clone, **never** the installed plugin dir.
- Lint contributed agents/skills and de-parameterize agents (strip every project-specific + secret
  value) before submitting.
- **Confirm with the user before opening** the PR/issue — it's public and outward-facing.
