#!/usr/bin/env bash
# shellcheck shell=bash
# git-remote.sh — derive the project's repo identity from its git remote (#73). The local directory
# is often cloned/renamed to something other than the repo name, so NAME / slug / wing should come
# from the ACTUAL remote repo name; the directory basename is only the LAST resort. Pure git + sed —
# no gh, no network, host-agnostic (github.com, GHE, GitLab, ssh/https). bash 3.2 + zsh compatible.
#
#   git_remote_slug [dir]       -> "owner/repo" from origin (rc 1 + empty when no remote)
#   git_remote_repo_name [dir]  -> "repo"
#   git_remote_owner [dir]      -> "owner"

git_remote_slug() {
  local dir="${1:-$PWD}" url
  url="$(git -C "$dir" remote get-url origin 2>/dev/null || true)"
  [ -n "$url" ] || return 1
  # Strip any scheme/host prefix (git@host:, ssh://git@host/, https://host/) and the trailing .git.
  printf '%s' "$url" | sed -E 's#^[a-z]+://[^/]+/##; s#^git@[^:]+:##; s#\.git$##; s#/$##'
}

git_remote_repo_name() { local s; s="$(git_remote_slug "${1:-$PWD}")" || return 1; printf '%s' "${s##*/}"; }
git_remote_owner()     { local s; s="$(git_remote_slug "${1:-$PWD}")" || return 1; printf '%s' "${s%%/*}"; }
