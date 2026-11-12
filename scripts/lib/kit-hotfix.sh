#!/usr/bin/env bash
# shellcheck shell=bash
# kit-hotfix.sh — `cckit hotfix <pr|sha> [--base <branch>]` (#360): carry ONE already-merged change
# to the release branch without waiting for the next promotion.
#
# `cckit pr` cannot do this on its own: it needs an issue (a cherry-pick of a merged PR has none) and
# it writes `Closes #N`. So the hotfix has its own path:
#
#   1. resolve the source — a PR number (its merge commit + title, read from GitHub; refused unless
#      MERGED) or a commit (its subject; the PR number is read from a squash `… (#N)` suffix or a
#      `Merge pull request #N` subject, when there is one)
#   2. worktree `.claude/worktrees/fix+<N>-hotfix-<base>` on branch `fix/<N>-hotfix-<base>`, cut
#      from origin/<base>   (`fix/hotfix-<sha7>-<base>` when the commit names no PR)
#   3. `git cherry-pick -x` (`-m 1` for a merge commit)
#   4. push, with the target exported to the git pre-push hook as KIT_PR_BASE
#   5. open the PR against <base>, titled after the source, body `Cherry-pick of #N`
#
# Re-runnable: a commit already picked is not picked again, and a PR already open for the branch is
# reported instead of re-created. A conflicting pick stops before the push — resolve it in the
# worktree, `git cherry-pick --continue`, and run the same command again.
#
#   kto_hotfix <pr|sha> [--base <branch>]
#     stdout: "worktree: <path>" then "✓ <pr-url>"
#     stderr: human progress
#     returns: 0 on success, 1 on a refusal or failed step, 2 on a usage error
#
# <base> defaults to KIT_HOTFIX_BASE, else `main`. A digits-only source (optionally `#`-prefixed) is
# a PR number; anything else is a commit.
# Requires: git, gh, jq. bash 3.2 compatible; sourceable under zsh.
# errors: strict — rc 1 on any failed step; nothing is pushed or opened after a failure
# Runs under the dispatcher's `set -e`: every read that may fail carries `|| true` and is checked
# on the next line, so a refusal prints its reason instead of exiting silently.

if ! type cckit_gh_rest >/dev/null 2>&1; then
  if [ -n "${BASH_SOURCE:-}" ]; then _kh_self="${BASH_SOURCE[0]}"
  elif [ -n "${ZSH_VERSION:-}" ]; then eval '_kh_self="${(%):-%x}"'
  else _kh_self="$0"; fi
  _kh_self="$(cd "$(dirname "$_kh_self")" 2>/dev/null && pwd)/gh-rest.sh"
  # shellcheck source=gh-rest.sh
  [ -f "$_kh_self" ] && . "$_kh_self"
  unset _kh_self
fi
type cckit_gh_rest >/dev/null 2>&1 || cckit_gh_rest() { return 1; }

_kh_usage() { echo 'cckit hotfix <pr|sha> [--base <branch>]   (base defaults to main)' >&2; }

# The PR number a commit subject names: a squash `… (#N)` suffix, or `Merge pull request #N …`.
# Empty when it names none.
kto_hotfix_subject_pr() {
  printf '%s\n' "$1" | sed -nE 's/^Merge pull request #([0-9]+) .*$/\1/p; s/^.* \(#([0-9]+)\)$/\1/p' | head -1
}

kto_hotfix() {
  local src="" base="" repo root sha="" title="" pr="" meta subject slug branch wt made="" url="" body n

  while [ $# -gt 0 ]; do
    case "$1" in
      --base)
        [ $# -ge 2 ] && [ -n "$2" ] || { echo "✗ hotfix: --base needs a branch name" >&2; _kh_usage; return 2; }
        base="$2"; shift 2 ;;
      --base=*) base="${1#--base=}"; shift ;;
      -h|--help) _kh_usage; return 0 ;;
      -*) echo "✗ hotfix: unknown flag '$1'" >&2; _kh_usage; return 2 ;;
      *)
        [ -z "$src" ] || { echo "✗ hotfix: one source only (got '$src' and '$1')" >&2; _kh_usage; return 2; }
        src="$1"; shift ;;
    esac
  done
  [ -n "$src" ] || { _kh_usage; return 2; }
  [ -n "$base" ] || base="${KIT_HOTFIX_BASE:-main}"
  [ -n "$base" ] || { echo "✗ hotfix: --base needs a branch name" >&2; return 2; }

  repo="${KIT_TASK_REPO:-${KIT_REPO:-}}"
  root="$(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2; exit}')"
  [ -n "$root" ] || { echo "✗ hotfix: not in a git repo" >&2; return 1; }

  git -C "$root" fetch --quiet origin "$base" 2>/dev/null \
    && git -C "$root" rev-parse --verify --quiet "refs/remotes/origin/$base" >/dev/null \
    || { echo "✗ hotfix: origin has no branch '$base'" >&2; return 1; }

  # 1. the source
  case "${src#\#}" in
    ''|*[!0-9]*)
      sha="$(git -C "$root" rev-parse --verify --quiet "$src^{commit}" 2>/dev/null || true)"
      if [ -z "$sha" ]; then
        git -C "$root" fetch --quiet origin 2>/dev/null || true
        sha="$(git -C "$root" rev-parse --verify --quiet "$src^{commit}" 2>/dev/null || true)"
      fi
      [ -n "$sha" ] || { echo "✗ hotfix: '$src' is not a commit in this repo" >&2; return 1; }
      subject="$(git -C "$root" log -1 --format=%s "$sha")"
      pr="$(kto_hotfix_subject_pr "$subject")"
      title="$(printf '%s\n' "$subject" | sed -E 's/ \(#[0-9]+\)$//')"
      ;;
    *)
      pr="${src#\#}"
      if cckit_gh_rest; then meta="$(gh_rest_pr_json "$repo" "$pr" || true)"
      else meta="$(gh pr view "$pr" --repo "$repo" --json title,state,mergeCommit || true)"; fi
      [ -n "$meta" ] || { echo "✗ hotfix: PR #$pr not found in $repo" >&2; return 1; }
      [ "$(printf '%s' "$meta" | jq -r '.state // ""')" = "MERGED" ] \
        || { echo "✗ hotfix: PR #$pr is not merged — a hotfix carries a change that already landed" >&2; return 1; }
      sha="$(printf '%s' "$meta" | jq -r '.mergeCommit.oid // ""')"
      title="$(printf '%s' "$meta" | jq -r '.title // ""')"
      [ -n "$sha" ] || { echo "✗ hotfix: PR #$pr has no merge commit" >&2; return 1; }
      git -C "$root" cat-file -e "$sha^{commit}" 2>/dev/null \
        || git -C "$root" fetch --quiet origin "$sha" 2>/dev/null \
        || git -C "$root" fetch --quiet origin 2>/dev/null || true
      git -C "$root" cat-file -e "$sha^{commit}" 2>/dev/null \
        || { echo "✗ hotfix: merge commit $sha of PR #$pr is not on origin" >&2; return 1; }
      ;;
  esac
  [ -n "$title" ] || title="hotfix: cherry-pick $(git -C "$root" rev-parse --short=7 "$sha")"

  # 2. the worktree, cut from origin/<base>
  slug="$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g')"
  if [ -n "$pr" ]; then branch="fix/$pr-hotfix-$slug"
  else branch="fix/hotfix-$(git -C "$root" rev-parse --short=7 "$sha")-$slug"; fi
  wt="$root/.claude/worktrees/$(printf '%s' "$branch" | tr '/' '+')"

  if git -C "$root" worktree list --porcelain | grep -qxF "worktree $wt"; then
    echo "[hotfix] reusing worktree $wt" >&2
  elif git -C "$root" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$root" worktree add "$wt" "$branch" >/dev/null 2>&1 \
      || { echo "✗ hotfix: worktree add failed (branch $branch may be checked out elsewhere)" >&2; return 1; }
    echo "[hotfix] created worktree $wt (existing branch $branch)" >&2
  else
    git -C "$root" worktree add --no-track -b "$branch" "$wt" "origin/$base" >/dev/null 2>&1 \
      || { echo "✗ hotfix: worktree add failed for $branch" >&2; return 1; }
    made=1
    echo "[hotfix] created worktree $wt (branch $branch from origin/$base)" >&2
    if type wt_bootstrap >/dev/null 2>&1; then wt_bootstrap "$root" "$wt" "${pr:-0}" >&2 || true; fi
  fi

  # 3. the pick
  if git -C "$wt" rev-parse --verify --quiet CHERRY_PICK_HEAD >/dev/null; then
    echo "✗ hotfix: a cherry-pick is still in progress in $wt" >&2
    echo "  resolve it, run \`git cherry-pick --continue\` there, then re-run this command" >&2
    return 1
  fi
  if git -C "$wt" log "origin/$base..HEAD" --format=%B | grep -qF "(cherry picked from commit $sha)"; then
    echo "[hotfix] $sha is already picked onto $branch" >&2
  else
    set -- -x
    n="$(git -C "$wt" rev-list --parents -n 1 "$sha" | wc -w | tr -d ' ')"
    if [ "$n" -gt 2 ]; then set -- "$@" -m 1; fi
    if ! git -C "$wt" cherry-pick "$@" "$sha" >&2; then
      if [ -z "$(git -C "$wt" status --porcelain --untracked-files=no)" ]; then
        # Nothing to commit: origin/<base> already carries this change.
        git -C "$wt" cherry-pick --abort >/dev/null 2>&1 || true
        if [ -n "$made" ]; then
          git -C "$root" worktree remove --force "$wt" >/dev/null 2>&1 || true
          git -C "$root" branch -D "$branch" >/dev/null 2>&1 || true
        fi
        echo "✗ hotfix: $sha changes nothing on origin/$base — it is already there" >&2
        return 1
      fi
      echo "✗ hotfix: the cherry-pick of $sha onto origin/$base conflicts" >&2
      echo "  resolve it in $wt, run \`git cherry-pick --continue\` there, then re-run this command" >&2
      return 1
    fi
  fi

  # 4. push — the target reaches a git pre-push hook as KIT_PR_BASE
  KIT_PR_BASE="$base" git -C "$wt" push -u origin "$branch" >&2 || return 1
  echo "worktree: $wt"

  # 5. the PR
  if cckit_gh_rest; then
    n="$(gh_rest_pr_for_head "$repo" "$branch" 2>/dev/null || true)"
    if [ -n "$n" ]; then url="https://github.com/$repo/pull/$n"; fi
  else
    url="$(gh pr list --repo "$repo" --head "$branch" --state open --json url --jq '.[0].url // empty' 2>/dev/null || true)"
  fi
  if [ -n "$url" ]; then
    echo "[hotfix] a PR is already open for $branch" >&2
    echo "✓ $url"
    return 0
  fi
  if [ -n "$pr" ]; then body="$(printf 'Cherry-pick of #%s onto `%s`.\n\nSource commit: %s' "$pr" "$base" "$sha")"
  else body="$(printf 'Cherry-pick of %s onto `%s`.' "$sha" "$base")"; fi
  if cckit_gh_rest; then
    url="$(gh_rest_pr_create "$repo" "$base" "$branch" "$title" "$body" "" "")" || return 1
  else
    url="$(gh pr create --repo "$repo" --base "$base" --head "$branch" \
      --title "$title" --body "$body" --assignee "@me")" || return 1
  fi
  echo "✓ $url"
}
