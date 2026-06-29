---
name: kit-security-sweep
description: Full security audit of the project's apps. A security expert scans for AI/prompt injection, auth/session weaknesses, CORS/CSP issues, and dependency CVEs; findings are filed as GitHub issues and roadmapped. Named kit-security-sweep (not security-review) so it doesn't shadow the Claude Code builtin /security-review (diff audit).
when_to_use: When you want a project security sweep with filed issues + roadmap entries — before a release, after a significant feature, or on demand. For a quick diff/code audit without issue filing, use the builtin /security-review instead.
---

# /kit-security-sweep

Plugin-direct skill — reads `.claude/kit.config.json` from the working directory; the project's
Security agent lives at `.claude/agents/security/AGENT.md`.

## What this process does

1. **Security expert** scans the active apps for vulnerabilities (see `.claude/agents/security/AGENT.md`)
2. A GitHub issue is filed for every finding (`role:security`, `kind:security`, severity label) — security findings file directly, no confirm round-trip
3. **Tech Lead** reviews findings and rolls them into the project's roadmap / a Security Hardening milestone

## Inputs

None required. Optionally pass `--app <name>` to scope to one app.

## Execution

### Phase 1 — Security Audit (Security agent)

Spawn the Security agent (`.claude/agents/security/AGENT.md`) with the full threat model from that file.
Ask it to output findings grouped by severity + a flat "Issues to file" list at the end.

### Phase 2 — Issue filing (PM)

For each finding, create a GitHub issue on the project repo (`KIT_REPO` from kit.config):

```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/kit-config.sh" && load_kit_config
gh issue create --repo "$KIT_REPO" \
  --title "<finding title>" \
  --label "role:security,kind:security,priority:<critical|p1|p2|p3>" \
  --body "<risk / evidence / fix>"
# add --milestone "<Security milestone>" when the project has one
```

### Phase 3 — Roadmap (Tech Lead)

Roll the filed issues into the project's roadmap surface / Security Hardening milestone.
CRITICAL findings block the distribution/release milestone.

## Output

- GitHub issues filed for every finding
- The project roadmap / Security Hardening milestone updated

## Rules

- Never mark a security finding as "won't fix" without explicit owner sign-off
- CRITICAL findings block the distribution/release milestone
- All security issues use label `role:security`
- Prompt injection findings also get label `kind:security`
