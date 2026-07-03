#!/usr/bin/env bash
# shellcheck shell=bash
# git-remote-test.sh — covers deriving the project's repo identity from the git remote (#73), so
# NAME / slug / wing come from the ACTUAL repo name (not a cloned/renamed directory basename). Also
# checks the host-agnostic URL parsing (ssh, https, GHE/GitLab). Hermetic: a throwaway git repo with
# a fake remote. Run:  bash scripts/lib/git-remote-test.sh
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$ROOT/scripts/lib"
fail=0
t()  { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
rc() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> rc '$2' want '$3'"; fail=1; fi; }
command -v git >/dev/null 2>&1 || { echo "git-remote-test: git required" >&2; exit 1; }

# shellcheck source=/dev/null
. "$LIB/git-remote.sh"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
cd "$tmp"; git init -q proj-dir-renamed; cd proj-dir-renamed   # dir name != repo name on purpose

# no remote yet -> rc 1, empty (so callers fall back to the basename)
out="$(git_remote_slug 2>/dev/null)"; r=$?
rc "no remote -> rc 1" "$r" "1"
t  "no remote -> empty" "$out" ""

set_remote() { git remote remove origin 2>/dev/null; git remote add origin "$1"; }

# ssh form
set_remote "git@github.com:acme/actual-repo.git"
t "ssh: slug"      "$(git_remote_slug)"      "acme/actual-repo"
t "ssh: repo name" "$(git_remote_repo_name)" "actual-repo"
t "ssh: owner"     "$(git_remote_owner)"     "acme"

# https form with .git
set_remote "https://github.com/acme/actual-repo.git"
t "https: slug"      "$(git_remote_slug)"      "acme/actual-repo"
t "https: repo name" "$(git_remote_repo_name)" "actual-repo"

# https without .git
set_remote "https://github.com/acme/actual-repo"
t "https no .git: repo name" "$(git_remote_repo_name)" "actual-repo"

# a non-GitHub host (GitLab) still parses (host-agnostic)
set_remote "git@gitlab.example.com:group/my-service.git"
t "GHE/GitLab: owner"     "$(git_remote_owner)"     "group"
t "GHE/GitLab: repo name" "$(git_remote_repo_name)" "my-service"

# ssh:// scheme form
set_remote "ssh://git@github.com/acme/another.git"
t "ssh:// scheme: repo name" "$(git_remote_repo_name)" "another"

# The whole point: repo name comes from the remote, NOT the (renamed) directory basename.
t "repo name != directory basename" "$(git_remote_repo_name)" "another"
[ "$(basename "$PWD")" = "proj-dir-renamed" ] && echo "ok: directory basename is indeed different" || { echo "FAIL: dir basename"; fail=1; }

[ "$fail" -eq 0 ] && echo "ALL OK (git-remote)" || echo "git-remote: FAILURES"
exit "$fail"
