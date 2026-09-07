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

# This file's own directory, resolved ONCE at load time — the only point where both shells agree.
# `BASH_SOURCE` is bash-only; inside a zsh *function* it is unset and `$0` is the function name, so
# the old per-call resolution fell back to `$0`="zsh", worktree-issue.sh was never sourced,
# `wt_protected_reason` stayed undefined, and every call site's `2>/dev/null || true` turned the
# resulting "command not found" into an empty reason — i.e. an open issue's branch classified as
# SAFE to delete. At FILE scope zsh sets `$0` to the sourced file's path, so one expansion covers
# bash (source or direct exec) and zsh (interactive or not) with no shell-specific syntax. Prompt
# expansion (`${(%):-%x}`) is deliberately avoided: it is zsh-only, needs `eval` to stay parseable
# under bash, and is unreliable in an INTERACTIVE zsh — the kit's own shell.
#
# `cd`'s own stdout is discarded, not just its stderr: an interactive zsh ECHOES the new directory
# (tilde-abbreviated) after a `cd`, so the bare `$(cd … && pwd)` idiom captured TWO lines and the
# resulting path never existed. `pwd` still writes to the substitution.
_KIT_GC_LIB_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd)"

# Source worktree-issue.sh (wt_issue_number / wt_protected_reason) from the lib dir we live in.
_kit_gc_load_deps() {
  command -v wt_protected_reason >/dev/null 2>&1 && return 0
  # shellcheck source=/dev/null
  [ -n "${_KIT_GC_LIB_DIR:-}" ] && [ -f "$_KIT_GC_LIB_DIR/worktree-issue.sh" ] \
    && . "$_KIT_GC_LIB_DIR/worktree-issue.sh"
  command -v wt_protected_reason >/dev/null 2>&1
}

# Fail LOUD if the protection helper could not be loaded. Without it every issue-open check
# silently returns empty and gc would offer to delete in-progress work — a wrong "safe" is far
# worse than a refusal, so callers must not proceed on a degraded analysis.
_kit_gc_require_deps() {
  _kit_gc_load_deps || :   # never let a load failure abort a `set -e` caller before the FATAL prints
  command -v wt_protected_reason >/dev/null 2>&1 && return 0
  echo "kit-gc: FATAL — worktree-issue.sh not loaded; issue-open protection is unavailable." >&2
  echo "kit-gc: refusing to classify branches: everything would look SAFE to delete." >&2
  return 1
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
  _kit_gc_require_deps || return 1
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

# _kit_gc_has_unpushed <branch> — rc 0 when the LOCAL branch holds commits its remote does not, i.e.
# deleting it locally would destroy the only copy. A missing remote ref is NOT unpushed work: the
# branch's PR merged, so the commits reached the base branch and the remote was deleted at merge.
# `git branch -D` is a force delete, so this is the guard that makes it safe (kit-gc SKILL: "verify a
# branch is level with its remote before deleting — an 'ahead' branch may hold orphan work").
_kit_gc_has_unpushed() {
  local b="$1"
  git show-ref --verify --quiet "refs/remotes/origin/$b" 2>/dev/null || return 1
  [ "$(git rev-list --count "origin/$b..$b" 2>/dev/null || echo 1)" != "0" ]
}

# _kit_gc_remote_ahead <branch> — rc 0 when the REMOTE holds commits the local branch does not.
# Containment in one direction is not equality: `origin/<b>..<b>` = 0 only proves local ⊆ remote, so
# a remote-ahead branch would otherwise pass the level check and lose remote-only history on delete.
# Remote deletion requires BOTH directions empty.
_kit_gc_remote_ahead() {
  local b="$1"
  git show-ref --verify --quiet "refs/remotes/origin/$b" 2>/dev/null || return 1
  [ "$(git rev-list --count "$b..origin/$b" 2>/dev/null || echo 1)" != "0" ]
}

# kit_gc_prune [--yes] - remove worktrees + local branches whose PR is MERGED (the SAFE rows).
# DRY-RUN by default (lists what it WOULD remove); --yes performs the deletions. Never touches a
# PROTECTED/ACTIVE/ORPHAN branch, and never a DIRTY worktree (recover-before-prune): a worktree with
# staged/unstaged/untracked changes is skipped with a warning, not destroyed. The remote branch is
# already deleted at merge time (gh pr merge --delete-branch); this cleans up the local side.
kit_gc_prune() {
  _kit_gc_require_deps || return 1
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
    # A merged PR is not on its own sufficient: the local ref may carry commits that were never
    # pushed, and `git branch -D` would be their last rites.
    if _kit_gc_has_unpushed "$b"; then
      echo "  SKIP $b — ahead of origin/$b (unpushed commits); recover before pruning" >&2; continue
    fi
    if [ "$yes" -eq 1 ]; then
      git branch -D "$b" >/dev/null 2>&1 && echo "  deleted local branch $b (PR MERGED)"
    else
      echo "  would delete local branch $b (PR MERGED)"
    fi
  done
  [ "$yes" -eq 1 ] && echo "gc prune: done" || echo "gc prune: DRY RUN - pass --yes to delete"
}

# _kit_gc_names <analysis> <section> <verdict-regex> — echo one bare name per matching row inside a
# `# <section>` block of a kit_gc_analyze dump. The analysis is the SINGLE classifier (Family 1):
# cleanup reads its verdicts rather than re-deriving them, so the two can never disagree about what
# is safe to delete — the failure mode #219 was about.
_kit_gc_names() {
  printf '%s\n' "$1" | awk -v sect="$2" -v want="$3" '
    /^# /     { in_s = ($0 == "# " sect); next }
    !in_s     { next }
    $0 ~ want { sub(/^  /, ""); sub(/ ->.*/, ""); print }
  '
}

# kit_gc_cleanup [--yes] — the ONE guided destructive sweep over the gc analysis.
#
# PLAN FIRST, always: print every bucket with its counts and names, then execute only the SAFE rows,
# and only with --yes. Without --yes nothing is written — the plan IS the output. Every row the plan
# omits is a deletion the user did not get to veto, so the plan must name EVERYTHING --yes can touch:
# worktrees as well as branches.
#
# What --yes deletes: merged worktrees, merged local branches (via kit_gc_prune, which also runs the
# recover-before-prune zombie pass), and the REMOTE ref of a merged branch that is exactly level with
# it. What it NEVER deletes: an ORPHAN branch (local commits not on the base remote), a PROTECTED
# branch (its issue is still open), or a stash. Those three are irreversible or hold the only copy of
# work, so they are surfaced BY NAME for a human and left exactly where they are.
#
# NOTE: the underlying kit_gc_analyze refreshes remote-tracking refs (`git fetch --prune`) so the
# classification is not made against a stale view of the remote. That is the only write a plan-only
# run performs, and it touches no branch, worktree, stash, or commit of yours.
kit_gc_cleanup() {
  _kit_gc_require_deps || return 1
  local repo="$KIT_GC_REPO" yes=0 a out b n_safe n_orphan n_prot n_stash n_wt rc=0
  local safe_list orphan_list prot_list stash_list wt_list level_ok
  for a in "$@"; do case "$a" in --yes|-y) yes=1 ;; esac; done

  out="$(kit_gc_analyze)" || return 1
  safe_list="$(_kit_gc_names "$out" branches ' -> SAFE ')"
  orphan_list="$(_kit_gc_names "$out" branches ' -> ORPHAN')"
  prot_list="$(_kit_gc_names "$out" branches ' -> PROTECTED:')"
  stash_list="$(printf '%s\n' "$out" | awk '/^# /{in_s=($0=="# stashes"); next} in_s && NF' | sed 's/^  //')"

  # Worktrees kit_gc_prune would remove: the ones whose branch is itself SAFE (same condition prune
  # applies — unprotected + PR MERGED). Derived from the SAFE list so the two cannot diverge.
  wt_list="$(git worktree list --porcelain 2>/dev/null \
    | awk '/^worktree /{w=$2} /^branch /{print w" "$2}' \
    | while read -r wtpath ref; do
        b="${ref#refs/heads/}"
        printf '%s\n' "$safe_list" | grep -qxF "$b" || continue
        if [ -n "$(git -C "$wtpath" status --porcelain 2>/dev/null)" ]; then
          echo "$wtpath [$b] (DIRTY — will be skipped, not destroyed)"
        else
          echo "$wtpath [$b]"
        fi
      done)"

  n_safe="$(printf '%s' "$safe_list"   | grep -c . || true)"
  n_orphan="$(printf '%s' "$orphan_list" | grep -c . || true)"
  n_prot="$(printf '%s' "$prot_list"   | grep -c . || true)"
  n_stash="$(printf '%s' "$stash_list" | grep -c . || true)"
  n_wt="$(printf '%s' "$wt_list"       | grep -c . || true)"

  echo "# cleanup plan"
  printf '  SAFE branches     %3s  merged PR, issue closed/absent\n' "$n_safe"
  printf '%s\n' "$safe_list" | grep . | sed 's/^/      /' || true
  printf '  SAFE worktrees    %3s  removed with their branch\n' "$n_wt"
  printf '%s\n' "$wt_list" | grep . | sed 's/^/      /' || true
  printf '  ORPHAN kept       %3s  commits not on the base remote — never auto-deleted\n' "$n_orphan"
  printf '%s\n' "$orphan_list" | grep . | sed 's/^/      /' || true
  printf '  PROTECTED kept    %3s  issue still OPEN\n' "$n_prot"
  printf '%s\n' "$prot_list" | grep . | sed 's/^/      /' || true
  printf '  stashes kept      %3s  irreversible — drop by hand after reading each diff\n' "$n_stash"
  printf '%s\n' "$stash_list" | grep . | sed 's/^/      /' || true

  if [ "$yes" -ne 1 ]; then
    echo "cleanup: PLAN ONLY — nothing deleted. Pass --yes to delete the SAFE rows."
    return 0
  fi
  [ "$n_safe" -eq 0 ] && [ "$n_wt" -eq 0 ] && { echo "cleanup: nothing SAFE to delete."; return 0; }

  # Which SAFE branches may have their REMOTE deleted — decided BEFORE the local prune, because once
  # the local ref is gone there is nothing left to compare. Requires exact equality in BOTH
  # directions: local ⊆ remote alone would let a remote-ahead branch lose remote-only history.
  level_ok=""
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    git show-ref --verify --quiet "refs/remotes/origin/$b" 2>/dev/null || continue
    _kit_gc_has_unpushed  "$b" && { echo "  SKIP remote $b — local is ahead of origin/$b" >&2; continue; }
    _kit_gc_remote_ahead  "$b" && { echo "  SKIP remote $b — origin/$b is ahead of local" >&2; continue; }
    level_ok="$level_ok$b
"
  done <<EOF
$safe_list
EOF

  kit_gc_prune --yes || rc=1

  # Remote side last: only branches proven exactly level above, so nothing unpushed or remote-only
  # is dropped. A failed delete is reported and counted, never retried blindly.
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    if git push origin --delete "$b" >/dev/null 2>&1; then
      echo "  deleted remote branch $b"
    else
      echo "  SKIP remote $b — delete failed (protected ref or already gone)" >&2; rc=1
    fi
  done <<EOF
$level_ok
EOF
  echo "cleanup: done — $n_orphan orphan / $n_prot protected / $n_stash stash left untouched."
  return "$rc"
}
