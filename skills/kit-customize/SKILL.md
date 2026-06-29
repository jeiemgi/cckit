---
name: kit-customize
description: Customize a kit-scaffolded project's .claude/ setup. Use AUTOMATICALLY whenever the user asks to create, add, edit, modify, rename, delete, or remove an agent in a project — and also to add a skill to an agent, attach skills, wire tools, find or search for a skill, suggest agents/skills for my project, lint my agents, validate an agent, build a custom profile, or pick a preset profile. Works on a project already scaffolded by /kit-init (a `.claude/` dir with `.claude/kit.config.json`).
argument-hint: "[add-agent <name> | add-skill <agent> | lint | profile]"
allowed-tools: Bash, Read, Edit, Write, Glob, Grep, AskUserQuestion, Skill
---

# kit-customize — tailor a kit-scaffolded project

You customize an **already-scaffolded** claude-kit project: add agents, wire skills + tools onto
them, search/suggest skills, lint everything, and apply a preset or custom profile. The kit (presets
+ templates) lives at `${CLAUDE_PLUGIN_ROOT}`; the project's setup lives in `./.claude/`.

## 1. Load context

- Read `./.claude/kit.config.json` → current `profile`, `roles`, `project.{name,slug,language}`,
  `memory.enabled`. **If it's missing, stop**: tell the user to run `/kit-init` first — this skill
  only customizes a project the kit already scaffolded.
- List existing agents: `.claude/agents/*/AGENT.md` (Glob). Note their `name`s.
- Available raw material:
  - Preset profiles → `${CLAUDE_PLUGIN_ROOT}/profiles/*.json`
  - Agent templates → `${CLAUDE_PLUGIN_ROOT}/templates/agents/<name>.md`
  - Skill templates → `${CLAUDE_PLUGIN_ROOT}/templates/skills/<name>/SKILL.md`

## 2. Pick a mode

If `$ARGUMENTS` names one (`add-agent`, `edit-agent`, `delete-agent`, `add-skill`, `lint`, `profile`),
use it. If the user's request clearly says create/add, edit/modify/rename, or delete/remove an agent,
go straight to that path in step 3 — don't ask the mode. Otherwise ask via `AskUserQuestion`:
**Add an agent** · **Edit an agent** · **Delete an agent** · **Add skills/tools** ·
**Search/suggest skills** · **Lint** · **Profile (preset or custom)**.

## 3. Add, edit, or delete an agent

**Add** — two paths, ask which:

- **From a kit template** — copy `${CLAUDE_PLUGIN_ROOT}/templates/agents/<name>.md`, then:
  - substitute `{{PROJECT_NAME}}`, `{{COMMS_LANG}}`, `{{WING}}`, `{{PROJECT_SLUG}}` etc. from
    `kit.config.json`;
  - resolve the `<!-- IF:MEMORY -->…<!-- /IF:MEMORY -->` block — **keep** its inner content when
    `memory.enabled` is true, **delete** the whole block (markers + body) when false.
- **Fresh custom agent** — author one that follows the frontmatter contract (see below).

Frontmatter contract (match the templates exactly):
```yaml
---
name: <slug>            # must equal the agent's directory name
description: <one line — what it owns + when it's invoked>
when_to_use: <trigger conditions>
tools: [Bash, Read, Edit, Write, Grep, Glob, mcp__server__tool, ...]
skills:
  - bare-global-skill
  - plugin:skill
---
```
Body: terse `## Authority` (✅ owns / ❌ defers + ❌ never), a numbered workflow, `## Voice + style`,
and (only if memory enabled) the `## Memory (MemPalace)` table.

Write to `.claude/agents/<name>/AGENT.md`. Then **lint it (step 6)**. Offer to:
- add the agent's role to `kit.config.json` `roles`, and
- add a row to the agent table in the project's `CLAUDE.md`.

**Edit** — open `.claude/agents/<name>/AGENT.md` and change frontmatter (`description`, `when_to_use`,
`tools`, `skills`) or body; for skills/tools specifically use step 4. To **rename**, move the dir to
`.claude/agents/<new>/AGENT.md`, set `name: <new>`, and update its role in `kit.config.json` + the
`CLAUDE.md` table. Keep edits additive; **re-lint (step 6)** after.

**Delete** — **confirm explicitly first** and show what will be removed. Then delete the whole
`.claude/agents/<name>/` directory and clean up references: drop the role from `kit.config.json`
`roles`, remove its row from the `CLAUDE.md` agent table, and grep `.claude/` for other mentions —
warn if any agent or rule still references it. Never delete without confirmation.

## 4. Add skills/tools to an agent

Open `.claude/agents/<name>/AGENT.md` and edit additively:

- **`skills:`** — append bare global names, `plugin:skill` refs, or scaffolded project skills.
- **`tools:`** — append builtins (`Bash`, `Read`, `Edit`, `Write`, `Grep`, `Glob`, `AskUserQuestion`)
  and domain `mcp__<server>__<tool>` names.

**Verify every name resolves before adding** (see step 5) — never invent a skill or tool name.
Re-lint (step 6) after editing.

## 5. Search / suggest skills (and tools)

- **Discover** — invoke the `find-skills` skill via the `Skill` tool, and enumerate what's already
  available: the session's skill list, `~/.claude/skills/*`, and installed plugin skills. For tools,
  scan the available `mcp__*` names in this session.
- **Suggest by profile/roles** — map the project to relevant skills + tools. Read what's actually
  available rather than hardcoding; the table below is illustrative:

  | Profile / role     | Skills (examples)                                                       | Tools (examples)        |
  | ------------------ | ----------------------------------------------------------------------- | ----------------------- |
  | software           | `agent-skills:context7`, `claude-api`, `playwright-best-practices`      | `mcp__chrome-devtools__*` |
  | design / content   | `tailwind-design-system`, `gsap-*`, `gws-slides`                        | `mcp__paper__*`         |
  | automation         | `n8n-*` (mcp-tools-expert, workflow-patterns, …)                       | `mcp__n8n__*`           |
  | research           | `deep-research`                                                         | `WebSearch`, `WebFetch` |

- Present the candidates and let the user pick which to wire into which agent → hand off to step 4.

## 6. Lint (must pass)

Validate one agent (`add-agent`/`add-skill` follow-up) or all (`lint` mode). Per file check:

| Check                | Pass condition                                                        |
| -------------------- | --------------------------------------------------------------------- |
| Frontmatter          | opens & closes with `---`; parses as valid YAML                       |
| Required keys        | `name`, `description`, `when_to_use`, `tools`, `skills` all present    |
| Name = dir           | `name` equals the parent directory name                               |
| Tools shape          | a list; each is a known builtin or matches `mcp__<server>__<tool>`     |
| Skills resolve       | a list; each resolves as global / `plugin:skill` / project skill — **warn** if not |
| No template tokens    | no leftover `{{VAR}}` in a scaffolded agent                           |

Report a table: **file · check · pass/warn/fail**, then offer to fix the fixable ones (missing keys,
name↔dir mismatch, unsubstituted tokens). For deeper skill authoring/validation, defer to
`agent-skills:skill-crafting` via the `Skill` tool.

## 7. Profile — preset or custom

- **Preset** — read `${CLAUDE_PLUGIN_ROOT}/profiles/*.json`, show each `label` + `description` +
  `agents`; on pick, scaffold/adapt its agents (step 3) and offer its `skills` to relevant agents.
- **Custom** — choose any subset/superset of agents (templates or fresh) + skills + `roles` +
  `milestones`. Offer to **save it for reuse** to `~/.claude/kit-profiles/<name>.json` using the
  preset JSON shape (`name`, `label`, `description`, `agents`, `skills`, `rules`, `roles`,
  `milestones`, `defaults`) — note it can feed a future `/kit-init` or kit-customize run.

Either way, update `.claude/kit.config.json` `profile` + `roles` to reflect the active selection.

## Rules

- Never overwrite an existing agent file without confirming.
- Always lint after writing or editing an agent (step 6).
- Don't invent skill or tool names — verify they resolve first (step 5).
- Keep every edit additive and reversible.
