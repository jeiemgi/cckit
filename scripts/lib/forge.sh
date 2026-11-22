#!/usr/bin/env bash
# shellcheck shell=bash
# forge.sh — the forge port (E537.2). cckit's core needs only git; a forge (today: GitHub) is an
# optional provider behind these functions. Callers use forge_* and never `gh` or the API URL.
#
#   forge_provider                       github | none — CCKIT_FORGE, else forge.provider in the
#                                        project config, else github when a token resolves, else none
#   forge_token                          the token: GH_TOKEN, GITHUB_TOKEN, else `gh auth token` when gh
#                                        is installed; empty when none resolves
#   forge_load                           source forge-<provider>.sh once (every forge_* below needs it)
#   forge_need [verb]                    rc 0 with a forge; without one, ONE line naming the verb that
#                                        needs it (CCKIT_VERB when the verb is not given), rc 1
#   forge_available                      rc 0 iff the provider is not none (no message)
#   forge_api <method> <path> [json]     raw REST call, the body on stdout; rc 1 on an HTTP error
#   forge_issue_view <repo> <n>          {number,title,body,state,labels[{name}],milestone{title,number},url}
#   forge_issue_create <repo> <title> <body> [labels-csv] [milestone-title]   → html_url
#   forge_issue_close <repo> <n> [completed|not_planned] [comment]
#   forge_issue_comment <repo> <n> <body>                                     → html_url
#   forge_issue_label <repo> <n> <labels-csv>                                  add labels
#   forge_issue_list <repo> [open|closed|all] [labels-csv]                     → [{number,title,state,labels[{name}]}]
#   forge_pr_open <repo> <base> <head> <title> <body> [labels-csv]            → html_url
#   forge_pr_view <repo> <n|head-branch> → {number,title,body,state,base,head,mergeable,merged,url}
#   forge_pr_merge <repo> <n> [squash|merge|rebase]
#   forge_pr_list <repo> [open|closed|all] [head-branch]                       → [{number,title,state,head,base,url}]
#
# <repo> is owner/name. Every function of the none provider refuses through forge_need.
# bash 3.2 + zsh compatible. Requires jq for the JSON forms.
# errors: strict — a refused forge call is rc 1 with its one line on stderr; HTTP errors propagate
_forge_self="${BASH_SOURCE[0]:-$0}"
FORGE_LIB="$(cd "$(dirname "$_forge_self")" && pwd)"
# shellcheck source=/dev/null
. "$FORGE_LIB/config-path.sh"

forge_token() {
  if [ -n "${GH_TOKEN:-}" ]; then printf '%s' "$GH_TOKEN"; return 0; fi
  if [ -n "${GITHUB_TOKEN:-}" ]; then printf '%s' "$GITHUB_TOKEN"; return 0; fi
  if command -v gh >/dev/null 2>&1; then gh auth token 2>/dev/null && return 0; fi
  return 1
}

# The configured provider, or empty when the config says nothing.
_forge_configured() {
  local cfg
  cfg="$(kit_config_path 2>/dev/null)" || return 0
  [ -f "$cfg" ] && command -v jq >/dev/null 2>&1 || return 0
  jq -r '.forge.provider // empty' "$cfg" 2>/dev/null
}

forge_provider() {
  local p
  p="${CCKIT_FORGE:-}"
  [ -n "$p" ] || p="$(_forge_configured)"
  case "$p" in
    github|none) printf '%s' "$p"; return 0 ;;
    '') ;;
    *) printf "cckit: forge.provider must be github or none (got '%s') — using the default\n" "$p" >&2 ;;
  esac
  if forge_token >/dev/null 2>&1; then printf 'github'; else printf 'none'; fi
}

forge_load() {
  [ -n "${_FORGE_LOADED:-}" ] && return 0
  local p; p="$(forge_provider)"
  # shellcheck source=/dev/null
  . "$FORGE_LIB/forge-$p.sh"
  _FORGE_LOADED="$p"
}

forge_available() { [ "$(forge_provider)" != "none" ]; }

forge_need() {
  forge_available && return 0
  local verb="${1:-${CCKIT_VERB:-cckit}}"
  printf 'cckit %s: needs a forge (GitHub) and none is configured. Set forge.provider to github and a token in GH_TOKEN, or sign in with gh. The git steps of %s run without one.\n' "$verb" "$verb" >&2
  return 1
}
