#!/bin/sh
# agent-def-test.sh — self-test for agent-def.sh under bash AND zsh (E257.6, #263).
# Hermetic: parses and translates a fixture role file.   Run: bash scripts/lib/agent-def-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion

dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

if [ -n "${AD_TEST_INNER:-}" ]; then
  . "$dir/agent-def.sh"
  fail=0
  t()   { if [ "$2" = "$3" ]; then :; else echo "FAIL($AD_TEST_INNER): $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
  has() { case "$2" in *"$3"*) ;; *) echo "FAIL($AD_TEST_INNER): $1 missing '[$3]'"; fail=1 ;; esac; }
  no()  { case "$2" in *"$3"*) echo "FAIL($AD_TEST_INNER): $1 has unexpected '[$3]'"; fail=1 ;; esac; }

  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  cat > "$tmp/tech-lead.md" <<'MD'
---
name: tech-lead
model: sonnet
description: Tech Lead. Owns the "build" system and C:\paths.
when_to_use: When the toolchain changes.
tools: [Bash, Read, Edit]
skills:
  - kit-task-pr # open the PR
  - 'agent-skills:context7'
---

# Tech Lead

Say "hello" and keep `a\b` literal.
MD
  printf -- '---\nname: editor\ndescription: Edits.\nskills: [one, two]\n---\nbody\n' > "$tmp/editor.md"
  printf -- '---\nname: bare\ndescription: Nothing listed.\nskills: []\n---\nbody\n' > "$tmp/bare.md"
  printf -- '---\nname: nodesc\n---\nbody\n' > "$tmp/nodesc.md"

  t "field: name"               "$(agent_def_field "$tmp/tech-lead.md" name)" "tech-lead"
  t "field: absent key is empty" "$(agent_def_field "$tmp/editor.md" model)" ""
  t "field: body text is not frontmatter" "$(agent_def_field "$tmp/tech-lead.md" Say)" ""
  t "skills: block list, comments and quotes stripped" "$(agent_def_skills "$tmp/tech-lead.md" | tr '\n' ' ')" "kit-task-pr agent-skills:context7 "
  t "skills: inline list"       "$(agent_def_skills "$tmp/editor.md" | tr '\n' ' ')" "one two "
  t "skills: empty inline list" "$(agent_def_skills "$tmp/bare.md")" ""
  t "body: starts at the first content line" "$(agent_def_body "$tmp/tech-lead.md" | head -1)" "# Tech Lead"
  t "codex name: hyphen becomes underscore" "$(agent_def_codex_name tech-lead)" "tech_lead"

  out="$(agent_def_codex "$tmp/tech-lead.md")"; t "codex: rc 0" "$?" "0"
  has "codex: name key"         "$out" 'name = "tech_lead"'
  has "codex: description carries when_to_use, quotes and backslashes escaped" "$out" 'description = "Tech Lead. Owns the \"build\" system and C:\\paths. When the toolchain changes."'
  has "codex: instructions open" "$out" 'developer_instructions = """'
  has "codex: body escaped"     "$out" 'Say \"hello\" and keep `a\\b` literal.'
  has "codex: skills listed"    "$out" '- agent-skills:context7'
  has "codex: tools named as untranslated" "$out" '# Not translated — Claude Code tool allowlist: [Bash, Read, Edit]'
  has "codex: model named as untranslated" "$out" '# Not translated — Claude model alias: sonnet'
  no  "codex: no tools key"     "$out" 'tools ='
  no  "codex: no model key"     "$out" 'model ='
  t "codex: instructions close once" "$(printf '%s\n' "$out" | grep -c '^"""$')" "1"
  no  "codex: no skills section without skills" "$(agent_def_codex "$tmp/bare.md")" "Skills this role names"
  agent_def_codex "$tmp/nodesc.md" >/dev/null 2>&1; t "codex: a role with no description is refused" "$?" "1"
  agent_def_codex "$tmp/missing.md" >/dev/null 2>&1; t "codex: a missing file is refused" "$?" "1"

  if [ "$fail" -eq 0 ]; then echo "PASS($AD_TEST_INNER): agent definition reader + Codex translation"; fi
  exit "$fail"
fi

rc=0
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || continue
  AD_TEST_INNER="$sh" "$sh" "$0" || rc=1
done
exit "$rc"
