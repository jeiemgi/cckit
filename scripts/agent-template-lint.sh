#!/usr/bin/env bash
# agent-template-lint.sh — every agent template carries the two fields both runtimes key on
# (E257.6, #263).
#
# WHY: templates/agents/<role>.md is the one role source, translated per adapter by
# scripts/lib/agent-def.sh. Codex refuses a custom agent whose TOML has no `name` or no
# `description`, and Claude Code addresses an agent by its `name`. A template whose `name:` drifted
# from its file name installs as `.codex/agents/<basename>.toml` declaring a different agent.
#
# WHAT: for each templates/agents/<role>.md, `name:` equals the file's basename and `description:`
# is not empty.
#
# Not here: whether a `skills:` entry resolves. scripts/agent-skills-lint.sh owns that check and its
# allowlist (scripts/agent-skills-external.txt); a second resolver here would be a second allowlist
# to keep in step.
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
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "agent-template-lint: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

# shellcheck source=/dev/null
. "$ROOT/scripts/lib/agent-def.sh"

AGENTS_DIR="$LINT_ROOT/templates/agents"
[ -d "$AGENTS_DIR" ] || { echo "agent-template-lint: no $AGENTS_DIR" >&2; exit 2; }

FAIL=0
err() { echo "x $1"; FAIL=1; }

count=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  count=$((count + 1))
  role="$(basename "$f" .md)"
  name="$(agent_def_field "$f" name)"
  [ "$name" = "$role" ] || err "$role: frontmatter name is '$name', expected '$role' (the file's basename)"
  [ -n "$(agent_def_field "$f" description)" ] || err "$role: empty description"
done <<EOF2
$(find "$AGENTS_DIR" -maxdepth 1 -type f -name '*.md' | LC_ALL=C sort)
EOF2

if [ "$FAIL" -eq 0 ]; then
  echo "ok agent templates: $count role(s), each with a name matching its file and a description"
fi
exit "$FAIL"
