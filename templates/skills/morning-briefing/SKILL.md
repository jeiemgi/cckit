---
name: morning-briefing
description: Daily briefing — what's active on the board, what's blocked, what to focus on.
when_to_use: When the owner starts their day or asks for a morning briefing / daily summary.
---

# Morning Briefing

## What it does

Reads GitHub (source of truth) + active plans, then delivers a concise briefing. Reads repo + plans dir from `.claude/kit.config.json`.

## How to run

```bash
source scripts/lib/kit-config.sh && load_kit_config
gh issue list --repo "$KIT_REPO" --state open --json number,title,labels,assignees --limit 30
# then scan $KIT_PLANS_DIR for active plans (anything not in archive/) if plans are enabled
```

Then produce:

---

**Buenos días.** · **Today is [day], [date].**

### Urgent
- [p1 issues open or blocked]

### Focus today
- [top 1–3 In Progress or unblocked items]

### On the radar
- [upcoming Todo items or active plans]

### Active plans
- [active plans by title; skip if none]

---

## Rules

- No long intros — straight to the briefing
- Bullets only · keep under 30 lines · skip empty sections
- Language: match the owner (see `.claude/rules/communication-style.md`)
- Source of truth is GitHub — never invent task state
