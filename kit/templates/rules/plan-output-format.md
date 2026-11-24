# Plan Output Format

## Hard rule

**When any agent is asked to produce a "plan", the deliverable is a file in `{{PLANS_DIR}}`** (format: `{{PLANS_FORMAT}}`).

Applies to: implementation plans, architecture plans, design briefs, roadmaps, milestone
breakdowns, audit reports, technical specs — anything labeled "plan" or "report".

## File convention

- Filename: `{{PROJECT_SLUG}}-<role>-<topic>.md` (or `.mdx` if your project renders MDX)
- Lives in `{{PLANS_DIR}}`
- Starts with YAML frontmatter:

```yaml
---
title: '{{PROJECT_NAME}} — <description>'
role: PM | Designer | Tech Lead | DevOps | Backend | Frontend | QA | Security | Research
date: YYYY-MM-DD
version: '1.0'
status: Draft | In Review | Active | Complete
subtitle: 'One-sentence description'
issue: 12 # GitHub issue number (optional)
tags: [tag1, tag2]
---
```

## Deliverables section (required)

Every plan must include a `## Deliverables` table listing the PRs that, when all merged, complete it:

```md
## Deliverables

| PR  | Description        | Status  |
| --- | ------------------ | ------- |
| #28 | Scaffold feature X | ⬜ Open |
| #29 | UI for feature X   | ⬜ Open |
```

This is the completion contract. When all PRs are merged → the plan flips `status:` to
`Complete` and **stays visible** in `{{PLANS_DIR}}` — there is no archive folder.

## Lifecycle

```
Draft → Active → Complete   (via the status: frontmatter field — file never moves)
```

`/kit-task-close` flips the status when closing the parent issue, once every Deliverables PR
is merged.

## Before writing a plan

1. Check `{{PLANS_DIR}}` for an existing plan on the same topic
2. Read project knowledge docs for background
3. Use the frontmatter + Deliverables skeleton above
