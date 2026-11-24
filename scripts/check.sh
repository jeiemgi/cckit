#!/usr/bin/env bash
# check.sh - cckit local gate. Runs the fast, dependency-light checks that must pass before a PR.
# No CI required; this is the bar. Exit non-zero on the first failure.
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"

fail=0
note() { printf '%s\n' "$*" >&2; }

# 1. Every shell script parses (bash -n).
note "==> shell syntax (bash -n)"
while IFS= read -r f; do
  bash -n "$f" || { note "x syntax: $f"; fail=1; }
done < <(find bin scripts -type f \( -name '*.sh' -o -perm -u+x \) 2>/dev/null | sort -u)

# 1b. shellcheck at error severity — static analysis when available, skipped if not installed
# (like jq below) so the gate stays dependency-light. CI installs shellcheck so this always runs there.
note "==> shellcheck (errors)"
if command -v shellcheck >/dev/null 2>&1; then
  find bin scripts -type f \( -name '*.sh' -o -name 'cckit' \) -print0 \
    | xargs -0 shellcheck --severity=error || fail=1
else
  note "  (shellcheck absent - skipping)"
fi

# 2. The plugin manifest is valid JSON.
note "==> plugin manifest JSON"
if command -v jq >/dev/null 2>&1; then
  jq -e . .claude-plugin/plugin.json >/dev/null || { note "x invalid plugin.json"; fail=1; }
  jq -e . cckit.config.json >/dev/null || { note "x invalid cckit.config.json"; fail=1; }
else
  note "  (jq absent - skipping JSON validation)"
fi

# 3. Leak fence - no private word (the legacy brand name, a product, a client, a person) in any
# tracked file. One scan, three pattern sources: the built-in word, the gitignored
# .cckit/leak-words list, and CCKIT_LEAK_WORDS in CI. Hits print as file:line only.
# scripts/lib/leak-fence.sh is the single implementation; scripts/leak-fence-test.sh is its selftest.
note "==> leak fence (tracked files)"
. scripts/lib/kit-state.sh 2>/dev/null || true
. scripts/lib/leak-fence.sh
leak_fence_check || fail=1

# 4. Secret + privacy guard - no secrets, keys, env, or private data in anything publishable.
# 3b. The forge fence (E537.5). Every GitHub call goes through scripts/lib/forge*.sh and gh-rest.sh;
# a file outside that layer calling gh or naming api.github.com fails here, against the ratchet in
# scripts/forge-fence.baseline (0 and 0).
note "==> forge fence"
bash scripts/forge-fence.sh || fail=1

note "==> secret + privacy guard"
if [ -f scripts/lib/secret-guard.sh ]; then
  . scripts/lib/secret-guard.sh
  secret_guard_scan || fail=1
fi

# 5. Skill frontmatter context budget. `description` + `when_to_use` are concatenated into the
# always-loaded skill listing - resident in every session whether or not the skill is invoked.
# Ratchet, not a hard cap: today's over-budget skills are grandfathered in the baseline file and
# only *growth* (or a new over-budget skill) fails the gate.
note "==> skill frontmatter context budget"
bash scripts/skill-frontmatter-lint.sh || fail=1

# 5b. Agent templates carry a `name:` equal to their file name and a non-empty `description:` —
# Codex refuses a custom agent without either (#263). Skill references are step 7's.
note "==> agent template name + description"
bash scripts/agent-template-lint.sh || fail=1

# 5c. Instruction-file budget. CLAUDE.md and every `.claude/rules/*.md` without a `paths:`
# frontmatter load into every session; Claude Code warns once they pass 150k characters combined.
# Same ratchet: an over-long file or an over-limit total is grandfathered in the baseline, and only
# growth (or a new offender) fails the gate.
note "==> instruction-file budget"
bash scripts/instruction-budget-lint.sh || fail=1

# 6. Codified review findings. Mechanical defect classes caught in past reviews, encoded as rules
# in scripts/review-rules.conf so the same bug cannot land twice. Per-file ratchet: today's hits are
# grandfathered in the baseline, only new or grown hits fail. Rules needing intent stay with review.
note "==> codified review findings"
bash scripts/review-lint.sh || fail=1

# 6b. Top-level verb count. scripts/lib/verbs.tsv may hold no more `verb` rows than
# scripts/verbs.baseline says, and a drop must lower the baseline in the same change. A rename keeps
# the old name as an alias row, which does not count (#557).
note "==> top-level verb ratchet"
bash scripts/verbs-ratchet.sh || fail=1

# 7. Agent skill references. Every `skills:` entry in templates/agents/*.md must resolve to a skill
# the kit ships or scaffolds, a `plugin:skill` reference, or a name declared third-party in
# scripts/agent-skills-external.txt. An unresolved entry fails silently at runtime: the agent loads
# with fewer skills than its frontmatter lists.
note "==> agent skill references"
bash scripts/agent-skills-lint.sh || fail=1

# 7b. Terms and skill routing — WARN mode. Every term under ontology/terms/ validates, every home
# resolves, every skill is routed and AGENTS.md's table mirrors skills/routing.yaml. It prints its
# defects and counts and never fails the gate: the terms are new and a word under discussion must
# not block an unrelated PR. scripts/terms-check-test.sh (step 8) is what fails on a broken checker.
note "==> terms and skill routing (warn mode)"
bash scripts/terms-check.sh || note "  (warning: terms-check found defects; the gate does not fail on them)"

# 8. Behavioral tests - run every *-test.sh through the test runner (several files at a time;
# TEST_JOBS=1 for one at a time).
note "==> behavioral tests"
bash scripts/test.sh || fail=1

[ "$fail" -eq 0 ] && note "PASS cckit check passed" || note "FAIL cckit check FAILED"
exit "$fail"
