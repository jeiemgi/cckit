#!/usr/bin/env bash
# kit-gc.sh — the canonical "garbage-collect the repo" git-mechanic (#373 / #419 extraction).
#
# Plugin mirror of the canonical scripts/lib/kit-gc.sh (#370 self-contained). Same op, one home.
# Family 1 of kit-engine-boundary.md (rule #1/#2): ONE bash home for the gc op, consumed by the
# kit-gc skill, `kit gc`, and the kit-ui Run cockpit (#816 — it shells `scripts/kit gc`). No second
# implementation. This extracts the read-only ANALYSIS — branch/worktree/stash classification with
# the issue-open protection — out of the skill so a UI can run a REAL verb (not just preview text).
#
# The DESTRUCTIVE prune stays interactive (the skill / a human drives the confirmed deletes); a
# headless surface only ever runs the analysis. That split is deliberate: `kit_gc_analyze` is safe
# to run anywhere, anytime (it writes nothing), so the cockpit can flip its `gc` verb to runnable.
#
#   kit_gc_analyze            print the classification table (read-only). rc 0 always.
#   kit_gc_has_prunable       rc 0 if anything is safe to delete (for a UI badge / nudge).
#
# Requires: git; gh (degrades to "unknown" issue/PR state without it); scripts/lib/worktree-issue.sh.
# Portable: bash 3.2+ AND zsh.

KIT_GC_REPO="${KIT_GC_REPO:-${KIT_REPO:-}}"

_kit_gc_root() { git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2; exit}'; }

# Source worktree-issue.sh (wt_issue_number / wt_protected_reason) from whatever lib dir we live in.
_kit_gc_load_deps() {
  command -v wt_protected_reason >/dev/null 2>&1 && return 0
  local d; d="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"
  # shellcheck source=/dev/null
  [ -f "$d/worktree-issue.sh" ] && . "$d/worktree-issue.sh"
}

# _kit_gc_pr_index [repo] — echo one "<headRefName>\tPR#<num> <STATE>" line per PR in ONE gh call, so
# branch classification is a local lookup instead of a per-branch `gh pr list --head` — an N+1 that
# scaled badly exactly when gc matters most (many stale branches). #124.
_kit_gc_pr_index() {
  local repo="${1:-$KIT_GC_REPO}"
  gh pr list --repo "$repo" --state all --limit 200 --json number,state,headRefName \
    --jq '.[] | "\(.headRefName)\tPR#\(.number) \(.state)"' 2>/dev/null || true
}

# _kit_gc_pr_for <index> <branch> — first PR line matching <branch> as head (mirrors the old `.[0]`).
_kit_gc_pr_for() {
  printf '%s\n' "$1" | awk -F'\t' -v want="$2" '$1==want{print $2; exit}'
}

# kit_gc_analyze — read-only classification of worktrees, branches, and stashes. Writes NOTHING.
# Each row is tagged PROTECTED / SAFE / ACTIVE / ORPHAN so a human or UI can decide what to prune.
kit_gc_analyze() {
  _kit_gc_load_deps
  # `wtpath`, not `path`: under zsh `path` is tied to PATH (special array), so a bare `path` local
  # here would clobber the command search path on assignment. A namespaced name is inert.
  local repo="$KIT_GC_REPO" b ref wtpath reason pr prot
  git fetch origin --prune --quiet 2>/dev/null || true

  echo "# worktrees"
  git worktree list --porcelain 2>/dev/null \
    | awk '/^worktree /{w=$2} /^branch /{print w" "$2}' \
    | while read -r wtpath ref; do
        b="${ref#refs/heads/}"
        reason="$(wt_protected_reason "$b" "$repo" 2>/dev/null || true)"
        if [ -n "$reason" ]; then echo "  $wtpath [$b] -> PROTECTED: $reason"
        else echo "  $wtpath [$b] -> prunable if PR merged"; fi
      done

  echo "# branches"
  # All PRs in ONE call, indexed locally by head branch (#124). while-read (NOT `for b in $(...)`) so
  # branch iteration survives a NUL-polluted IFS.
  local pr_index; pr_index="$(_kit_gc_pr_index "$repo")"
  git branch --format='%(refname:short)' 2>/dev/null | while IFS= read -r b; do
    [ -n "$b" ] || continue
    case "$b" in "${KIT_BASE_BRANCH:-main}"|develop|main) echo "  $b -> ACTIVE (base branch)"; continue;; esac
    pr="$(_kit_gc_pr_for "$pr_index" "$b")"
    prot="$(wt_protected_reason "$b" "$repo" 2>/dev/null || true)"
    if [ -n "$prot" ]; then
      echo "  $b -> PROTECTED: $prot"
    elif printf '%s' "$pr" | grep -q 'MERGED'; then
      echo "  $b -> SAFE (${pr}, issue closed/absent — verify level with remote before delete)"
    elif printf '%s' "$pr" | grep -q 'OPEN'; then
      echo "  $b -> ACTIVE (${pr})"
    else
      echo "  $b -> ${pr:-ORPHAN (no PR — surface, never auto-delete)}"
    fi
  done

  echo "# stashes"
  git stash list 2>/dev/null | sed 's/^/  /' || true

  echo "# zombies (worktree dir gone, admin metadata lingers)"
  local zname zbranch zstaged found=0
  while IFS="$(printf '\t')" read -r zname zbranch zstaged; do
    [ -n "$zname" ] || continue
    found=1
    if [ "$zstaged" = yes ]; then
      echo "  $zname [$zbranch] -> ZOMBIE with STAGED work — recover-before-prune (gc --prune --yes recovers it to a commit)"
    else
      echo "  $zname [$zbranch] -> ZOMBIE (no staged delta) — prunable"
    fi
  done <<EOF
$(_kit_gc_zombies)
EOF
  [ "$found" -eq 1 ] || echo "  (none)"
}

# kit_gc_has_prunable — rc 0 if at least one branch is SAFE to delete (a merged, unprotected branch).
kit_gc_has_prunable() {
  kit_gc_analyze 2>/dev/null | grep -q '> SAFE '
}

# _kit_gc_zombies — echo "<name>\t<branch>\t<staged:yes|no>" for each ZOMBIE worktree: its working
# dir is gone but its admin metadata (<git-common-dir>/worktrees/<name>/) lingers. staged=yes when
# the admin index holds a tree that differs from the branch tip (staged-but-uncommitted work that
# `git worktree prune` would orphan). Writes NOTHING. bash 3.2.
_kit_gc_zombies() {
  local common wdir name gitdir wtpath branch tree tip tiptree staged
  common="$(git rev-parse --git-common-dir 2>/dev/null)" || return 0
  case "$common" in /*) : ;; *) common="$(cd "$common" 2>/dev/null && pwd)" || return 0 ;; esac
  [ -d "$common/worktrees" ] || return 0
  for wdir in "$common"/worktrees/*/; do
    [ -d "$wdir" ] || continue
    gitdir="$(cat "$wdir/gitdir" 2>/dev/null)"; wtpath="${gitdir%/.git}"
    # A zombie: the recorded working-tree path is set but no longer exists on disk.
    [ -n "$wtpath" ] && [ ! -e "$wtpath" ] || continue
    name="$(basename "$wdir")"
    branch="$(sed -n 's#^ref: refs/heads/##p' "$wdir/HEAD" 2>/dev/null)"
    tree=""; [ -f "$wdir/index" ] && tree="$(GIT_INDEX_FILE="$wdir/index" git write-tree 2>/dev/null)"
    tip="$(git rev-parse --verify --quiet "refs/heads/${branch}" 2>/dev/null)"
    tiptree=""; [ -n "$tip" ] && tiptree="$(git rev-parse --verify --quiet "${tip}^{tree}" 2>/dev/null)"
    if [ -n "$tree" ] && [ "$tree" != "$tiptree" ]; then staged=yes; else staged=no; fi
    printf '%s\t%s\t%s\n' "$name" "${branch:-?}" "$staged"
  done
}

# kit_gc_recover_zombies <yes> — the recover-before-prune mechanic (#111). For each ZOMBIE worktree
# holding staged-but-uncommitted work, recover that delta to its branch via plumbing BEFORE any
# prune: GIT_INDEX_FILE=<admin>/index git write-tree -> git commit-tree -p <tip> -> update-ref. With
# <yes>=1 it performs the recovery + sweeps that zombie's stale locks; otherwise it reports what it
# WOULD recover (dry-run). Never prunes; that stays with the caller (gated on --yes). bash 3.2.
kit_gc_recover_zombies() {
  local yes="${1:-0}" common wdir name gitdir wtpath branch tree tip tiptree newc msg
  common="$(git rev-parse --git-common-dir 2>/dev/null)" || return 0
  case "$common" in /*) : ;; *) common="$(cd "$common" 2>/dev/null && pwd)" || return 0 ;; esac
  [ -d "$common/worktrees" ] || return 0
  for wdir in "$common"/worktrees/*/; do
    [ -d "$wdir" ] || continue
    gitdir="$(cat "$wdir/gitdir" 2>/dev/null)"; wtpath="${gitdir%/.git}"
    [ -n "$wtpath" ] && [ ! -e "$wtpath" ] || continue    # only dead worktrees
    name="$(basename "$wdir")"
    branch="$(sed -n 's#^ref: refs/heads/##p' "$wdir/HEAD" 2>/dev/null)"
    [ -f "$wdir/index" ] || continue
    tree="$(GIT_INDEX_FILE="$wdir/index" git write-tree 2>/dev/null)" || continue
    [ -n "$tree" ] || continue
    tip="$(git rev-parse --verify --quiet "refs/heads/${branch}" 2>/dev/null)"
    tiptree=""; [ -n "$tip" ] && tiptree="$(git rev-parse --verify --quiet "${tip}^{tree}" 2>/dev/null)"
    # No staged delta beyond the tip → nothing to recover; the zombie is safe to prune as-is.
    [ "$tree" = "$tiptree" ] && continue
    [ -n "$branch" ] || { echo "  gc: zombie $name is detached with staged work — leaving it for manual recovery" >&2; continue; }
    if [ "$yes" -ne 1 ]; then
      echo "  would RECOVER staged work from zombie worktree $name -> a commit on $branch (staged tree $tree)" >&2
      continue
    fi
    msg="kit gc: recovered staged work from zombie worktree $name (recover-before-prune)"
    newc="$(printf '%s\n' "$msg" | GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-kit-gc}" GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-kit-gc@localhost}" GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-kit-gc}" GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-kit-gc@localhost}" git commit-tree "$tree" ${tip:+-p "$tip"} 2>/dev/null)"
    if [ -n "$newc" ]; then
      # Compare-and-swap on the tip so a concurrent update is never clobbered.
      if git update-ref "refs/heads/$branch" "$newc" ${tip:+"$tip"} 2>/dev/null; then
        echo "  RECOVERED staged work from zombie $name -> commit ${newc%% *} on $branch" >&2
      else
        echo "  gc: could not update refs/heads/$branch (moved concurrently?) — zombie $name left intact" >&2
      fi
    fi
    # Stale-lock sweep — safe only because this worktree is provably dead.
    rm -f "$wdir/index.lock" "$wdir/HEAD.lock" 2>/dev/null || true
  done
}

# kit_gc_prune [--yes] - remove worktrees + local branches whose PR is MERGED (the SAFE rows).
# DRY-RUN by default (lists what it WOULD remove); --yes performs the deletions. Never touches a
# PROTECTED/ACTIVE/ORPHAN branch, and never a DIRTY worktree (recover-before-prune): a worktree with
# staged/unstaged/untracked changes is skipped with a warning, not destroyed. The remote branch is
# already deleted at merge time (gh pr merge --delete-branch); this cleans up the local side.
kit_gc_prune() {
  _kit_gc_load_deps
  # `wtpath`, not `path`: under zsh `path` is tied to PATH (special array), so assigning to a bare
  # `path` local would clobber the command search path. A namespaced name is inert.
  local repo="$KIT_GC_REPO" yes=0 a wtpath ref b pr pr_index
  for a in "$@"; do case "$a" in --yes|-y) yes=1 ;; esac; done

  # All PRs in ONE call, indexed by head branch (#124) — shared by both loops below instead of a
  # per-branch `gh pr list --head` (the N+1 that scaled badly with many stale branches).
  pr_index="$(_kit_gc_pr_index "$repo")"

  # Worktrees first - a branch's worktree must be removed before the branch can be deleted.
  git worktree list --porcelain 2>/dev/null \
    | awk '/^worktree /{w=$2} /^branch /{print w" "$2}' \
    | while read -r wtpath ref; do
        b="${ref#refs/heads/}"
        case "$b" in "${KIT_BASE_BRANCH:-main}"|develop|main|"") continue ;; esac
        [ -n "$(wt_protected_reason "$b" "$repo" 2>/dev/null || true)" ] && continue
        pr="$(_kit_gc_pr_for "$pr_index" "$b")"
        printf '%s' "$pr" | grep -q 'MERGED' || continue
        if [ -n "$(git -C "$wtpath" status --porcelain 2>/dev/null)" ]; then
          echo "  SKIP dirty worktree $wtpath [$b] - commit/recover before pruning" >&2; continue
        fi
        if [ "$yes" -eq 1 ]; then
          git worktree remove --force "$wtpath" 2>/dev/null && echo "  removed worktree $wtpath [$b]"
        else
          echo "  would remove worktree $wtpath [$b] (PR MERGED)"
        fi
      done

  # recover-before-prune (#111): a zombie worktree (working dir gone, admin metadata lingers) may
  # hold staged-but-uncommitted work in its admin index — the ONLY blob->path map. `git worktree
  # prune` deletes that index, orphaning the blobs for a later `git gc` to reap — real data loss in a
  # documented incident. Recover any staged delta to its branch FIRST, and gate the prune sweep
  # behind --yes so it NEVER runs in a dry-run (the previous unconditional prune was the hazard).
  kit_gc_recover_zombies "$yes"
  [ "$yes" -eq 1 ] && { git worktree prune 2>/dev/null || true; }

  # Then local branches whose PR merged (worktree now gone). while-read (NOT `for b in $(...)`) so
  # branch iteration survives a NUL-polluted IFS (#124).
  git branch --format='%(refname:short)' 2>/dev/null | while IFS= read -r b; do
    [ -n "$b" ] || continue
    case "$b" in "${KIT_BASE_BRANCH:-main}"|develop|main) continue ;; esac
    [ -n "$(wt_protected_reason "$b" "$repo" 2>/dev/null || true)" ] && continue
    pr="$(_kit_gc_pr_for "$pr_index" "$b")"
    printf '%s' "$pr" | grep -q 'MERGED' || continue
    if [ "$yes" -eq 1 ]; then
      git branch -D "$b" >/dev/null 2>&1 && echo "  deleted local branch $b (PR MERGED)"
    else
      echo "  would delete local branch $b (PR MERGED)"
    fi
  done
  [ "$yes" -eq 1 ] && echo "gc prune: done" || echo "gc prune: DRY RUN - pass --yes to delete"
}
