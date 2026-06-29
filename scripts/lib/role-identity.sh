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
KIT_ROLE_EMAIL_DOMAIN="${KIT_ROLE_EMAIL_DOMAIN:-agents.local}"
KIT_AGENT_LABEL="${KIT_AGENT_LABEL:-agent}"

# role_display <slug> -> human label (empty for unknown/blank)
role_display() {
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
    *)         echo "" ;;
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
