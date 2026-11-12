#!/usr/bin/env bash
# agent-template-lint-test.sh — the agent-template lint fails on a skill that does not exist
# (E257.6, #263). Hermetic: every case lints a throwaway tree via --root, plus one run over the
# repo's own templates, which must be clean.   Run: bash scripts/agent-template-lint-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LINT="$ROOT/scripts/agent-template-lint.sh"
fail=0
t()   { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
has() { case "$2" in *"$3"*) echo "ok: $1" ;; *) echo "FAIL: $1 (missing '$3' in: $2)"; fail=1 ;; esac; }

fx="$(mktemp -d)"; trap 'rm -rf "$fx"' EXIT
tree() {  # tree <name> — a minimal lint root: one plugin skill, one template skill, one external
  mkdir -p "$fx/$1/templates/agents" "$fx/$1/skills/kit-task-sync" "$fx/$1/templates/skills/morning-briefing"
  : > "$fx/$1/skills/kit-task-sync/SKILL.md"; : > "$fx/$1/templates/skills/morning-briefing/SKILL.md"
  printf '# externals\next:thing   # provided by another plugin\n' > "$fx/$1/templates/agents/EXTERNAL_SKILLS"
}
role() {  # role <tree> <name> <skills-yaml…>
  local d="$fx/$1/templates/agents" n="$2"; shift 2
  { printf -- '---\nname: %s\ndescription: The %s role.\ntools: [Bash]\n' "$n" "$n"; printf '%s\n' "$@"; printf -- '---\n\n# body\n'; } > "$d/$n.md"
}
lint() { bash "$LINT" --root "$fx/$1" 2>&1; }

# 1. every form of a resolvable skill passes: plugin skill, template skill, declared external
tree good
role good pm 'skills:' '  - kit-task-sync # the board' '  - morning-briefing' '  - ext:thing'
role good editor 'skills: []'
out="$(lint good)"; t "resolvable skills pass (rc)" "$?" "0"
has "clean run reports the role count" "$out" "2 role(s)"

# 2. a skill that does not exist fails, and the finding names the role and the skill
tree dead
role dead pm 'skills:' '  - task-sync' '  - ext:thing'
out="$(lint dead)"; t "a dead skill fails (rc)" "$?" "1"
has "finding names the role and skill" "$out" "pm: skill 'task-sync' does not exist"

# 3. the inline list form is read too
tree inline
role inline pm 'skills: [kit-task-sync, nope, ext:thing]'
out="$(lint inline)"; t "inline list: dead skill fails (rc)" "$?" "1"
has "inline list: finding names the skill" "$out" "skill 'nope' does not exist"

# 4. an EXTERNAL line no template names is an error, so the list cannot become allow-everything
tree stale
role stale pm 'skills:' '  - kit-task-sync'
out="$(lint stale)"; t "a stale EXTERNAL line fails (rc)" "$?" "1"
has "stale EXTERNAL line is named" "$out" "EXTERNAL_SKILLS: 'ext:thing' is named by no agent template"

# 5. a shipped skill must not also be declared external
tree both
role both pm 'skills:' '  - kit-task-sync' '  - ext:thing'
printf 'kit-task-sync\n' >> "$fx/both/templates/agents/EXTERNAL_SKILLS"
out="$(lint both)"; t "shipped + external fails (rc)" "$?" "1"
has "shipped + external is named" "$out" "'kit-task-sync' is shipped by cckit and also listed"

# 6. name must equal the basename and description must be present (both runtimes key on them)
tree meta
role meta pm 'skills: [ext:thing]'
sed -i.bak 's/^name: pm$/name: project-manager/; s/^description: .*$/description:/' "$fx/meta/templates/agents/pm.md" && rm -f "$fx/meta/templates/agents/pm.md.bak"
out="$(lint meta)"; t "bad name/description fails (rc)" "$?" "1"
has "name mismatch is named" "$out" "frontmatter name is 'project-manager', expected 'pm'"
has "empty description is named" "$out" "pm: empty description"

# 7. the repo's own templates are clean — this is the gate check.sh runs
out="$(bash "$LINT" 2>&1)"; t "repo templates pass (rc)" "$?" "0"
t "pm no longer names the dead task-* skills" "$(grep -cE '^  - task-(sync|new|close)$' "$ROOT/templates/agents/pm.md")" "0"

[ "$fail" -eq 0 ] && echo "PASS: agent-template lint" || echo "FAILED"
exit "$fail"
