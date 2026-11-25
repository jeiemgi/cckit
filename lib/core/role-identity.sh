#!/usr/bin/env bash
# role-identity.sh — cheap per-role identity (NO separate GitHub accounts).
#
# Maps a role slug (designer, backend, tech-lead, …) to a git commit AUTHOR and a
# one-line signature. The GitHub actor stays the maintainer's token — this only sets
# the commit *author* and a signature line so a role's work READS as that role.
# Real distinct handles/avatars are a separate, heavier effort (bot accounts / GitHub App).
#
# Source it:  source scripts/lib/role-identity.sh
#
# Tunables (env):
#   KIT_ROLE_EMAIL_DOMAIN  synthetic author-email domain (default: agents.local — not a real inbox)
#   KIT_AGENT_LABEL        suffix in the author/sig label (default: agent)
# errors: pure — maps a role slug to an author + signature; an unknown slug prints an empty line
KIT_ROLE_EMAIL_DOMAIN="${KIT_ROLE_EMAIL_DOMAIN:-agents.local}"
KIT_AGENT_LABEL="${KIT_AGENT_LABEL:-agent}"

# role_display <slug> -> human label (empty for unknown/blank)
# The fixed list covers every role a shipped profile declares. A slug outside it resolves through
# the project's own roles (KIT_ROLES, newline-delimited display names from `roles` in the config,
# exported by load_kit_config): "Brand Lead" answers for `brand-lead`. So a role a project adds to
# its config signs its commits and pull requests without a code change here (#416).
role_display() {
  local _rd_role _rd_slug
  case "$1" in
    editor)     echo "Editor"; return 0 ;;
    researcher) echo "Researcher"; return 0 ;;
    analyst)    echo "Analyst"; return 0 ;;
    automation) echo "Automation"; return 0 ;;
    generalist) echo "Generalist"; return 0 ;;
  esac
  case "$1" in
    designer)  echo "Designer" ;;
    devops)    echo "DevOps" ;;
    pm)        echo "PM" ;;
    frontend)  echo "Frontend" ;;
    tauri)     echo "Tauri" ;;
    ai-eng)    echo "AI Eng" ;;
    security)  echo "Security" ;;
    qa)        echo "QA" ;;
    tech-lead) echo "Tech Lead" ;;
    research)  echo "Research" ;;
    backend)   echo "Backend" ;;
    '')        echo "" ;;
    *)
      # No pipe and no `<<<`: this file is sourced by bash 3.2 and zsh, and the loop must set the
      # answer in this shell.
      while IFS= read -r _rd_role; do
        [ -n "$_rd_role" ] || continue
        _rd_slug="$(printf '%s' "$_rd_role" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')"
        if [ "$_rd_slug" = "$1" ]; then printf '%s\n' "$_rd_role"; return 0; fi
      done <<_RD_EOF
${KIT_ROLES:-}
_RD_EOF
      echo "" ;;
  esac
}

# role_git_author <slug> -> "Name|email"  (empty when no/unknown role: caller keeps the default identity)
role_git_author() {
  local d; d="$(role_display "$1")"
  [[ -z "$d" ]] && return 0
  printf '%s (%s)|%s@%s' "$d" "$KIT_AGENT_LABEL" "$1" "$KIT_ROLE_EMAIL_DOMAIN"
}

# role_signature <slug> -> one markdown line for issue/PR bodies (empty when no role)
role_signature() {
  local d; d="$(role_display "$1")"
  [[ -z "$d" ]] && return 0
  printf -- '— %s · %s (acting via the maintainer account)' "$d" "$KIT_AGENT_LABEL"
}
