#!/usr/bin/env bash
# agent-skills-lint.sh — resolve every `skills:` entry in templates/agents/*.md (kit-owned).
#
# WHY: a skill reference that does not resolve fails silently. The agent loads, answers, and has
# fewer capabilities than its frontmatter lists; nothing warns at init time or later. A rename is
# how it happens: templates/agents/pm.md kept listing task-sync / task-new / task-close after the
# kit shipped them as kit-task-*, so all three of the PM agent's lifecycle skills were dead.
#
# WHAT: an entry resolves when it is one of
#   - a skill the kit ships:            skills/<name>/SKILL.md
#   - a skill the kit scaffolds:        templates/skills/<name>/SKILL.md
#   - another plugin's skill:           <plugin>:<skill>  (the namespace names the provider)
#   - a declared third-party bare name: a line in scripts/agent-skills-external.txt
# Anything else fails, reported as `<file>:<line>: <entry>`. An allowlisted name that the kit now
# ships fails too, so the allowlist cannot keep describing a kit skill as third-party.
#
# Only the frontmatter `skills:` key is read (block list or inline `[a, b]`); body prose is not.
# No baseline: every entry resolves or the gate is red. bash 3.2 compatible.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

AGENTS_DIR="templates/agents"
EXTERNAL="scripts/agent-skills-external.txt"

FAIL=0
err()  { echo "x $1"; FAIL=1; }
note() { echo "  $1"; }

if [ ! -d "$AGENTS_DIR" ]; then
  echo "agent-skills-lint: no $AGENTS_DIR directory — nothing to lint"
  exit 0
fi

# Prints "<line>\t<entry>" for each entry of the frontmatter `skills:` key. Trailing `# comments`
# and quotes are stripped; an empty inline list prints nothing.
skills_entries() {
  awk '
    function emit(n, s) {
      sub(/[ \t]+#.*$/, "", s)
      gsub(/^[ \t"\047]+|[ \t"\047]+$/, "", s)
      if (length(s)) printf "%d\t%s\n", n, s
    }
    NR == 1 && $0 == "---" { infm = 1; next }
    !infm { exit }
    $0 == "---" { exit }
    /^skills:/ {
      grab = 1
      rest = $0
      sub(/^skills:[ \t]*/, "", rest)
      if (rest ~ /^\[/) {
        gsub(/^\[|\].*$/, "", rest)
        n = split(rest, parts, ",")
        for (i = 1; i <= n; i++) emit(NR, parts[i])
        grab = 0
      }
      next
    }
    grab && /^[ \t]*-[ \t]*/ { s = $0; sub(/^[ \t]*-[ \t]*/, "", s); emit(NR, s); next }
    grab && /^[^ \t#]/ { grab = 0 }
  ' "$1"
}

shipped() { [ -f "skills/$1/SKILL.md" ] || [ -f "templates/skills/$1/SKILL.md" ]; }

external_names() {
  [ -f "$EXTERNAL" ] || return 0
  sed -e 's/#.*$//' -e 's/[[:space:]]*$//' -e 's/^[[:space:]]*//' "$EXTERNAL" | grep -v '^$'
}
is_external() { grep -qxF -- "$1" <<<"$(external_names)"; }

# The allowlist may not name a skill the kit ships.
while IFS= read -r name; do
  [ -n "$name" ] || continue
  if shipped "$name"; then
    err "$EXTERNAL: $name is shipped by the kit — remove it from the third-party list"
  fi
done <<EOF_NAMES
$(external_names)
EOF_NAMES

agents=0
entries=0
dead=0
for f in "$AGENTS_DIR"/*.md; do
  [ -f "$f" ] || continue
  agents=$(( agents + 1 ))
  while IFS="$(printf '\t')" read -r line entry; do
    [ -n "$entry" ] || continue
    entries=$(( entries + 1 ))
    if grep -qE '^[a-z0-9][a-z0-9-]*:[a-z0-9][a-z0-9-]*$' <<<"$entry"; then
      continue
    fi
    if grep -qE '^[a-z0-9][a-z0-9-]*$' <<<"$entry"; then
      shipped "$entry" && continue
      is_external "$entry" && continue
    fi
    err "$f:$line: $entry"
    dead=$(( dead + 1 ))
  done <<EOF_ENTRIES
$(skills_entries "$f")
EOF_ENTRIES
done

if [ "$dead" -gt 0 ]; then
  note "$dead skills: entr$( [ "$dead" -eq 1 ] && echo y || echo ies ) resolve to nothing: not under skills/ or templates/skills/,"
  note "not a plugin:skill reference, and not in $EXTERNAL."
  note "A renamed kit skill takes its new name; a third-party one gets a line in $EXTERNAL."
fi

if [ "$FAIL" -eq 0 ]; then
  echo "ok agent skills resolve ($entries entries across $agents agents)"
fi
exit "$FAIL"
