#!/usr/bin/env bash
# shellcheck shell=bash
# agent-def.sh — read a specialist role template and translate it per runtime (E257.6, #263).
#
# A role lives ONCE, in templates/agents/<role>.md: YAML frontmatter (name, description, tools,
# skills) over a markdown body of responsibilities. Claude Code reads that file as-is, installed at
# .claude/agents/<role>/AGENT.md. Codex reads a custom agent as TOML at .codex/agents/<role>.toml
# with three required keys — name, description, developer_instructions. This file is the one
# translation, so the two definitions cannot drift apart: both come from the same rendered role.
#
# What does NOT translate, and is written into the TOML as a comment rather than dropped silently:
#   tools:  a Claude Code tool allowlist. Codex has no per-agent tool list; its sandbox and
#           approval policy govern the agent instead.
#   model:  a Claude model alias. cckit never names a model for another runtime.
#
#   agent_def_field <file> <key>     one frontmatter scalar (empty when absent)
#   agent_def_skills <file>          the skills: list, one name per line (inline or block form)
#   agent_def_body <file>            the markdown after the frontmatter
#   agent_def_codex_name <role>      the Codex agent name for a role (tech-lead -> tech_lead)
#   agent_def_codex <file>           stdout: the Codex TOML for an already-rendered role file
#
# bash 3.2 + zsh compatible: awk and sed only, no arrays.
# errors: strict — agent_def_codex returns 1 when the role has no name or no description, because
# Codex refuses an agent file missing either and a silent empty value would install a dead agent.

agent_def_field() {
  awk -v key="${2:-}" '
    NR == 1 && /^---[[:space:]]*$/ { fm = 1; next }
    fm && /^---[[:space:]]*$/ { exit }
    fm && index($0, key ":") == 1 {
      v = substr($0, length(key) + 2)
      sub(/^[[:space:]]+/, "", v); sub(/[[:space:]]+$/, "", v)
      print v; exit
    }' "${1:-/dev/null}"
}

agent_def_skills() {
  awk '
    NR == 1 && /^---[[:space:]]*$/ { fm = 1; next }
    fm && /^---[[:space:]]*$/ { exit }
    !fm { next }
    /^skills:/ {
      inlist = 1
      v = $0; sub(/^skills:[[:space:]]*/, "", v)
      if (v ~ /^\[/) {
        gsub(/[][]/, "", v)
        n = split(v, parts, ",")
        for (i = 1; i <= n; i++) { p = parts[i]; gsub(/^[[:space:]]+|[[:space:]]+$/, "", p); if (p != "") print p }
        inlist = 0
      }
      next
    }
    inlist && /^[[:space:]]+-[[:space:]]/ {
      v = $0; sub(/^[[:space:]]+-[[:space:]]+/, "", v); sub(/[[:space:]]+#.*$/, "", v)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v); gsub(/^["\047]|["\047]$/, "", v)
      if (v != "") print v
      next
    }
    inlist && /^[^[:space:]]/ { inlist = 0 }' "${1:-/dev/null}"
}

agent_def_body() {
  awk '
    NR == 1 && /^---[[:space:]]*$/ { fm = 1; next }
    fm == 1 && /^---[[:space:]]*$/ { fm = 2; next }
    fm == 1 { next }
    !started && /^[[:space:]]*$/ { next }
    { started = 1; print }' "${1:-/dev/null}"
}

agent_def_codex_name() { printf '%s\n' "${1:-}" | tr '-' '_'; }

# TOML basic-string escaping: a backslash and a double quote are the only two characters that can
# end or corrupt a basic string, single- or multi-line. Escaping every quote (not just runs of
# three) keeps one rule for both string forms.
_agent_def_toml_escape() { sed 's/\\/\\\\/g; s/"/\\"/g'; }

agent_def_codex() {
  local f="${1:-}" name desc when tools model skills
  [ -f "$f" ] || { echo "agent-def: no such role file: $f" >&2; return 1; }
  name="$(agent_def_field "$f" name)"
  desc="$(agent_def_field "$f" description)"
  when="$(agent_def_field "$f" when_to_use)"
  tools="$(agent_def_field "$f" tools)"
  model="$(agent_def_field "$f" model)"
  skills="$(agent_def_skills "$f")"
  [ -n "$name" ] || { echo "agent-def: $f has no name: in its frontmatter" >&2; return 1; }
  [ -n "$desc" ] || { echo "agent-def: $f has no description: in its frontmatter" >&2; return 1; }
  [ -z "$when" ] || desc="$desc $when"

  printf '# Codex custom agent for the %s role. cckit init renders it from templates/agents/%s.md,\n' "$name" "$name"
  printf '# the same role source the Claude Code adapter installs as AGENT.md.\n'
  [ -z "$tools" ] || printf '# Not translated — Claude Code tool allowlist: %s\n' "$tools"
  [ -z "$model" ] || printf '# Not translated — Claude model alias: %s\n' "$model"
  printf 'name = "%s"\n' "$(agent_def_codex_name "$name" | _agent_def_toml_escape)"
  printf 'description = "%s"\n' "$(printf '%s' "$desc" | _agent_def_toml_escape)"
  printf 'developer_instructions = """\n'
  agent_def_body "$f" | _agent_def_toml_escape
  if [ -n "$skills" ]; then
    printf '\n## Skills this role names\n\n'
    printf 'Codex loads a skill only when it is installed (the project .agents/skills/ or your Codex\n'
    printf 'home). A kit-* name is a Claude Code plugin skill: in Codex, run the cckit verb it wraps.\n\n'
    printf '%s\n' "$skills" | sed 's/^/- /' | _agent_def_toml_escape
  fi
  printf '"""\n'
}
