#!/usr/bin/env bash
# agent-template-lint-test.sh — the agent-template lint fails on a template whose `name:` is not its
# file name or whose `description:` is empty (E257.6, #263). Hermetic: every case lints a throwaway
# tree via --root, plus one run over the repo's own templates, which must be clean. Whether a
# `skills:` entry resolves is scripts/agent-skills-lint-test.sh's subject, not this file's.
# Run: bash scripts/agent-template-lint-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LINT="$ROOT/scripts/agent-template-lint.sh"
fail=0
t()   { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
has() { case "$2" in *"$3"*) echo "ok: $1" ;; *) echo "FAIL: $1 (missing '$3' in: $2)"; fail=1 ;; esac; }

fx="$(mktemp -d)"; trap 'rm -rf "$fx"' EXIT
role() {  # role <tree> <name>
  mkdir -p "$fx/$1/templates/agents"
  printf -- '---\nname: %s\ndescription: The %s role.\ntools: [Bash]\nskills: []\n---\n\n# body\n' "$2" "$2" > "$fx/$1/templates/agents/$2.md"
}
lint() { bash "$LINT" --root "$fx/$1" 2>&1; }

# 1. templates with a matching name and a description pass
role good pm; role good editor
out="$(lint good)"; t "well-formed templates pass (rc)" "$?" "0"
has "clean run reports the role count" "$out" "2 role(s)"

# 2. name must equal the basename and description must be present (both runtimes key on them)
role meta pm
sed -i.bak 's/^name: pm$/name: project-manager/; s/^description: .*$/description:/' "$fx/meta/templates/agents/pm.md" && rm -f "$fx/meta/templates/agents/pm.md.bak"
out="$(lint meta)"; t "bad name/description fails (rc)" "$?" "1"
has "name mismatch is named" "$out" "frontmatter name is 'project-manager', expected 'pm'"
has "empty description is named" "$out" "pm: empty description"

# 3. a tree with no templates/agents is a usage error, not a silent pass
mkdir -p "$fx/none"
lint none >/dev/null; t "a root with no templates/agents is rc 2" "$?" "2"

# 4. the repo's own templates are clean — this is the gate check.sh runs
out="$(bash "$LINT" 2>&1)"; t "repo templates pass (rc)" "$?" "0"

[ "$fail" -eq 0 ] && echo "PASS: agent-template lint" || echo "FAILED"
exit "$fail"
