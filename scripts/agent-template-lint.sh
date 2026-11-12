#!/usr/bin/env bash
# agent-template-lint.sh — every skill an agent template names must exist (E257.6, #263; #208).
#
# WHY: a `skills:` entry that does not resolve fails silently. The agent loads, answers, and is
# less capable than its frontmatter claims, with nothing surfacing the gap. templates/agents/pm.md
# named `task-sync`, `task-new` and `task-close` for months after those skills became
# `kit-task-sync`, `kit-task-new` and `kit-task-close` — the agent that drives the task lifecycle
# could not name one skill that does it.
#
# WHAT: for each templates/agents/<role>.md, every `skills:` entry must be one of
#   - a skill cckit ships as a plugin skill:   skills/<name>/SKILL.md
#   - a skill cckit scaffolds into a project:  templates/skills/<name>/SKILL.md
#   - a skill declared EXTERNAL:               one line of templates/agents/EXTERNAL_SKILLS
# EXTERNAL is the explicit marker for a skill another plugin or the user provides. It is a claim
# that the name is intentional, not a proof the skill is installed — cckit cannot see the user's
# other plugins. An EXTERNAL line no template names any more is itself an error, so the list cannot
# rot into an allow-everything file.
#
# Also checked, because both runtimes need them: `name:` equals the file's basename, and
# `description:` is not empty (Codex refuses a custom agent without either).
#
#   scripts/agent-template-lint.sh                 lint this repo (the gate; rc 1 on any finding)
#   scripts/agent-template-lint.sh --root <dir>    lint another tree with the same layout (tests)
#
# bash 3.2 compatible.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LINT_ROOT="$ROOT"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)   LINT_ROOT="$2"; shift 2 ;;
    --root=*) LINT_ROOT="${1#*=}"; shift ;;
    -h|--help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "agent-template-lint: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

# shellcheck source=/dev/null
. "$ROOT/scripts/lib/agent-def.sh"

AGENTS_DIR="$LINT_ROOT/templates/agents"
EXTERNAL="$AGENTS_DIR/EXTERNAL_SKILLS"
[ -d "$AGENTS_DIR" ] || { echo "agent-template-lint: no $AGENTS_DIR" >&2; exit 2; }

FAIL=0
err() { echo "x $1"; FAIL=1; }

external_list() {
  [ -f "$EXTERNAL" ] || return 0
  grep -vE '^[[:space:]]*(#|$)' "$EXTERNAL" | sed 's/[[:space:]]*#.*$//; s/^[[:space:]]*//; s/[[:space:]]*$//'
}
is_shipped()  { [ -f "$LINT_ROOT/skills/$1/SKILL.md" ] || [ -f "$LINT_ROOT/templates/skills/$1/SKILL.md" ]; }
is_external() { external_list | grep -qxF -- "$1"; }

used="$(mktemp)"; trap 'rm -f "$used"' EXIT
count=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  count=$((count + 1))
  role="$(basename "$f" .md)"
  name="$(agent_def_field "$f" name)"
  [ "$name" = "$role" ] || err "$role: frontmatter name is '$name', expected '$role' (the file's basename)"
  [ -n "$(agent_def_field "$f" description)" ] || err "$role: empty description"
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    printf '%s\n' "$s" >> "$used"
    if is_shipped "$s"; then
      is_external "$s" && err "$role: '$s' is shipped by cckit and also listed in EXTERNAL_SKILLS — remove the EXTERNAL line"
    elif ! is_external "$s"; then
      err "$role: skill '$s' does not exist — not under skills/ or templates/skills/, and not declared in templates/agents/EXTERNAL_SKILLS"
    fi
  done <<EOF
$(agent_def_skills "$f")
EOF
done <<EOF
$(find "$AGENTS_DIR" -maxdepth 1 -type f -name '*.md' | LC_ALL=C sort)
EOF

while IFS= read -r e; do
  [ -n "$e" ] || continue
  grep -qxF -- "$e" "$used" || err "EXTERNAL_SKILLS: '$e' is named by no agent template — remove the line"
done <<EOF
$(external_list)
EOF

if [ "$FAIL" -eq 0 ]; then
  echo "ok agent templates: $count role(s), every named skill resolves"
fi
exit "$FAIL"
