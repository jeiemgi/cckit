#!/usr/bin/env bash
# shellcheck shell=bash
# task-source-file.sh — the `file` task source (#450): one tracked file per light task.
#
#   <tasks.dir>/<id>.md        (tasks.dir defaults to `tasks`, at the checkout root)
#
#   id: t3f9a
#   title: Write the spring newsletter
#   status: todo
#   priority: p2
#   kind: task
#   created: 2026-11-12
#
#   Free-form notes after the first blank line.
#
# The header is one `key: value` per line up to the first blank line. `status` is `todo`, `done`
# or `dropped` (set `dropped` by hand to abandon a task); anything else reads as `todo`.
#
# ONE FILE PER TASK, because two branches that each add a task must merge without a conflict. Two
# appends to one shared file land on the same lines and conflict in git; two new files never touch.
# Finishing a task rewrites one line (`status:`) of one file.
#
# STATE IS DERIVED from where the file is and what it says — there is no second record to keep in
# step. For a task id, in this order:
#   done / dropped   the base branch's copy says so (the pull request that finished it merged)
#   review           a `light/<id>-<slug>` branch exists and its copy says `done`
#   doing            a `light/<id>-<slug>` branch exists
#   todo             the base branch has the file
#   shared           a `light/share-<stamp>` branch has the file and the base branch does not yet:
#                    `cckit task share` committed it and its pull request has not merged
#   draft            only this checkout has the file (not committed anywhere a teammate can see)
# The base branch is read as `origin/<base>` when that ref exists, else the local `<base>`.
# Branches are local heads first, then the cached `origin/light/*` refs. No op here uses the
# network; the verbs fetch before they list.
#
# Implements the interface in task-source.sh; called only through task_source_call.
# Requires: git. bash 3.2 + zsh (no glob held in a variable, no `status`/`path` variable names).
# errors: mixed — reads are forgiving (a missing file is an absent task); writes return 1

_tsf_top() { git rev-parse --show-toplevel 2>/dev/null; }

_tsf_base_ref() {
  local base="${KIT_BASE_BRANCH:-main}"
  if git show-ref --verify --quiet "refs/remotes/origin/$base" 2>/dev/null; then printf 'origin/%s' "$base"
  elif git show-ref --verify --quiet "refs/heads/$base" 2>/dev/null; then printf '%s' "$base"
  fi
}

# _tsf_field <key> — stdin: a task file. Print the header value of <key>, or nothing.
_tsf_field() {
  awk -v k="$1" '
    NF == 0 { exit }
    { i = index($0, ":")
      if (i && substr($0, 1, i - 1) == k) {
        v = substr($0, i + 1); sub(/^[ \t]+/, "", v); sub(/[ \t\r]+$/, "", v); print v; exit
      } }'
}

# _tsf_branch <id> — the task's branch as a ref git can read: a local `light/<id>-…` head, else a
# cached `origin/light/<id>-…`. Nothing when the task has no branch.
_tsf_branch() {
  local b
  b="$(git for-each-ref --format='%(refname:short)' "refs/heads/light/$1-*" 2>/dev/null | sed -n 1p)"
  [ -n "$b" ] || b="$(git for-each-ref --format='%(refname:short)' "refs/remotes/origin/light/$1-*" 2>/dev/null | sed -n 1p)"
  printf '%s' "$b"
}

_tsf_closed() { case "$1" in done|dropped) return 0 ;; esac; return 1; }

# _tsf_share_refs — every `light/share-<stamp>` ref: local heads first, then the cached origin ones.
_tsf_share_refs() {
  git for-each-ref --format='%(refname:short)' 'refs/heads/light/share-*' \
    'refs/remotes/origin/light/share-*' 2>/dev/null
}

# _tsf_share_ref <id> — the first share ref whose tree carries the task's file, or nothing.
_tsf_share_ref() {
  local top dir r
  top="$(_tsf_top)" || return 0
  [ -n "$top" ] || return 0
  dir="$(task_source_dir)"
  _tsf_share_refs | while IFS= read -r r; do
    if git -C "$top" cat-file -e "$r:$dir/$1.md" 2>/dev/null; then printf '%s' "$r"; break; fi
  done
}

# _tsf_ids — every task id visible from this checkout: its tasks dir, the base branch, the
# `light/*` branches, and the files a `light/share-*` branch carries.
_tsf_ids() {
  local top dir base r
  top="$(_tsf_top)" || return 0
  [ -n "$top" ] || return 0
  dir="$(task_source_dir)"; base="$(_tsf_base_ref)"
  {
    if [ -d "$top/$dir" ]; then ls "$top/$dir" 2>/dev/null | grep '\.md$' | sed 's/\.md$//'; fi
    if [ -n "$base" ]; then
      git -C "$top" ls-tree --name-only "$base" "$dir/" 2>/dev/null | grep '\.md$' | sed 's|.*/||; s/\.md$//'
    fi
    _tsf_share_refs | while IFS= read -r r; do
      git -C "$top" ls-tree --name-only "$r" "$dir/" 2>/dev/null || true
    done | grep '\.md$' | sed 's|.*/||; s/\.md$//'
    git for-each-ref --format='%(refname)' refs/heads/light/ refs/remotes/origin/light/ 2>/dev/null \
      | sed -E 's#^refs/(heads|remotes/origin)/light/##; s/-.*$//'
  } | while IFS= read -r id; do
    if task_id_valid "$id"; then printf '%s\n' "$id"; fi
  done | sort -u
}

# _tsf_row <id> — the task's TSV row; rc 1 when no copy of the file can be read.
_tsf_row() {
  local id="$1" top dir base rel br="" c_base="" c_br="" c_wt="" content state s sr=""
  top="$(_tsf_top)" || return 1
  [ -n "$top" ] || return 1
  dir="$(task_source_dir)"; base="$(_tsf_base_ref)"; rel="$dir/$id.md"
  if [ -n "$base" ]; then c_base="$(git -C "$top" show "$base:$rel" 2>/dev/null || true)"; fi
  br="$(_tsf_branch "$id")"
  if [ -n "$br" ]; then c_br="$(git -C "$top" show "$br:$rel" 2>/dev/null || true)"; fi
  if [ -f "$top/$rel" ]; then c_wt="$(cat "$top/$rel" 2>/dev/null || true)"; fi

  s="$(printf '%s\n' "$c_base" | _tsf_field status)"
  if [ -n "$c_base" ] && _tsf_closed "$s"; then
    state="$s"; content="$c_base"
  elif [ -n "$br" ] && [ -n "${c_br:-$c_base$c_wt}" ]; then
    content="${c_br:-${c_base:-$c_wt}}"
    if [ "$(printf '%s\n' "$c_br" | _tsf_field status)" = "done" ]; then state="review"; else state="doing"; fi
  elif [ -n "$c_base" ]; then
    state="todo"; content="$c_base"
  elif sr="$(_tsf_share_ref "$id")" && [ -n "$sr" ]; then
    state="shared"; br="$sr"; content="$(git -C "$top" show "$sr:$rel" 2>/dev/null || true)"
  elif [ -n "$c_wt" ]; then
    content="$c_wt"; s="$(printf '%s\n' "$c_wt" | _tsf_field status)"
    if _tsf_closed "$s"; then state="$s"; else state="draft"; fi
  else
    return 1
  fi

  local title prio kind created
  title="$(printf '%s\n' "$content" | _tsf_field title)"
  prio="$(printf '%s\n' "$content" | _tsf_field priority)"
  kind="$(printf '%s\n' "$content" | _tsf_field kind)"
  created="$(printf '%s\n' "$content" | _tsf_field created)"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$state" "${prio:-p2}" "${kind:-task}" "${created:--}" \
    "${br:--}" "$(printf '%s' "${title:-(untitled)}" | tr '\t' ' ')"
}

# task_file_list — every task, ordered: doing, review, todo, draft, shared, done, dropped; inside a state
# by priority, then creation date, then id.
task_file_list() {
  local id
  _tsf_ids | while IFS= read -r id; do
    [ -n "$id" ] || continue
    _tsf_row "$id" || true
  done | awk -F'\t' '
    BEGIN { r["doing"] = 1; r["review"] = 2; r["todo"] = 3; r["draft"] = 4; r["shared"] = 5; r["done"] = 8; r["dropped"] = 9 }
    { print (($2 in r) ? r[$2] : 7) "\t" $3 "\t" $5 "\t" $1 "\t" $0 }' \
    | sort -t "$(printf '\t')" -k1,1n -k2,2 -k3,3 -k4,4 | cut -f5-
}

# task_file_get <id|prefix> — the one row whose id is <id>, else the one whose id starts with it.
task_file_get() {
  local want="${1:-}" rows n
  [ -n "$want" ] || { echo "✗ a task id is required" >&2; return 1; }
  if task_id_valid "$want" && rows="$(_tsf_row "$want")" && [ -n "$rows" ]; then
    printf '%s\n' "$rows"; return 0
  fi
  rows="$(task_file_list | awk -F'\t' -v w="$want" 'index($1, w) == 1')"
  n="$(printf '%s\n' "$rows" | grep -c . || true)"
  if [ "$n" -eq 0 ]; then
    echo "✗ no task '$want' — see 'cckit task list --all'" >&2; return 1
  elif [ "$n" -gt 1 ]; then
    echo "✗ '$want' matches $n tasks: $(printf '%s\n' "$rows" | cut -f1 | tr '\n' ' ')" >&2; return 3
  fi
  printf '%s\n' "$rows"
}

_tsf_exists() {
  local id="$1" top dir base
  top="$(_tsf_top)"; dir="$(task_source_dir)"; base="$(_tsf_base_ref)"
  [ -f "$top/$dir/$id.md" ] && return 0
  [ -n "$base" ] && git -C "$top" cat-file -e "$base:$dir/$id.md" 2>/dev/null && return 0
  [ -n "$(_tsf_branch "$id")" ] && return 0
  [ -n "$(_tsf_share_ref "$id")" ] && return 0
  return 1
}

# _tsf_new_id <seed> — `t` + 4 hex digits not used by any task this checkout can see. Not a
# counter: two branches that each took "the next number" would both create task 7.
_tsf_new_id() {
  local seed="$1" i=0 h id
  while [ "$i" -lt 64 ]; do
    h="$(printf '%s|%s|%s|%s|%s' "$seed" "$$" "$(date +%s 2>/dev/null)" "${RANDOM:-0}" "$i" \
      | git hash-object --stdin 2>/dev/null | cut -c1-4)"
    id="t$h"
    if [ -n "$h" ] && ! _tsf_exists "$id"; then printf '%s' "$id"; return 0; fi
    i=$((i + 1))
  done
  return 1
}

# task_file_create <title> <priority> <kind> <body> — write the task file into THIS checkout and
# print the id. Nothing is committed: the file travels with the branch that starts or shares it.
task_file_create() {
  local title="$1" prio="${2:-p2}" kind="${3:-task}" body="${4:-}" top dir id f
  top="$(_tsf_top)"
  [ -n "$top" ] || { echo "✗ not inside a git repository" >&2; return 1; }
  dir="$(task_source_dir)"
  title="$(printf '%s' "$title" | tr '\n\t' '  ' | sed -E 's/^ +| +$//g')"
  [ -n "$title" ] || { echo "✗ a title is required" >&2; return 1; }
  id="$(_tsf_new_id "$title")" || { echo "✗ could not allocate a task id" >&2; return 1; }
  mkdir -p "$top/$dir" || return 1
  f="$top/$dir/$id.md"
  {
    printf 'id: %s\ntitle: %s\nstatus: todo\npriority: %s\nkind: %s\ncreated: %s\n' \
      "$id" "$title" "$prio" "$kind" "$(date +%Y-%m-%d)"
    if [ -n "$body" ]; then printf '\n%s\n' "$body"; fi
  } > "$f" || return 1
  printf '%s\n' "$id"
}

# _tsf_untracked <checkout> <rel> — rc 0 when <rel> exists there and git does not track it.
_tsf_untracked() {
  [ -f "$1/$2" ] && ! git -C "$1" ls-files --error-unmatch -- "$2" >/dev/null 2>&1
}

# task_file_on_start <id> <worktree> <from-checkout> — make sure the task file is committed on the
# task's branch. When the base branch does not have it yet (a draft), it is copied from the checkout
# the start was run in and committed; an untracked original is then removed, because a file left
# untracked there blocks the pull that later brings the merged copy.
task_file_on_start() {
  local id="$1" wt="$2" from="$3" dir rel
  dir="$(task_source_dir)"; rel="$dir/$id.md"
  if git -C "$wt" cat-file -e "HEAD:$rel" 2>/dev/null; then return 0; fi
  if [ ! -f "$wt/$rel" ]; then
    [ -f "$from/$rel" ] || { echo "✗ task $id has no file at $rel" >&2; return 1; }
    mkdir -p "$wt/$dir" && cp "$from/$rel" "$wt/$rel" || return 1
  fi
  git -C "$wt" add -- "$rel" >/dev/null 2>&1 \
    && git -C "$wt" commit -q -m "chore(tasks): add $id" -- "$rel" >/dev/null 2>&1 \
    || { echo "✗ could not commit $rel on the task branch" >&2; return 1; }
  if [ "$from" != "$wt" ] && _tsf_untracked "$from" "$rel"; then
    rm -f "$from/$rel"; rmdir "$from/$dir" 2>/dev/null || true
    echo "[$id] moved $rel onto the task branch" >&2
  fi
  return 0
}

# task_file_on_finish <id> <worktree> — set `status: done` in the worktree's copy and stage the
# tasks dir (so a task created in this worktree ships with it). The mark reaches the base branch
# when the pull request merges, which is what makes the task done.
task_file_on_finish() {
  local id="$1" wt="$2" dir rel tmp
  dir="$(task_source_dir)"; rel="$dir/$id.md"
  [ -f "$wt/$rel" ] || { echo "✗ task $id has no file at $rel in $wt" >&2; return 1; }
  tmp="$(mktemp)" || return 1
  if [ -n "$(_tsf_field status < "$wt/$rel")" ]; then
    awk 'BEGIN { h = 1 } h && NF == 0 { h = 0 }
         h && !d && /^status:/ { print "status: done"; d = 1; next } { print }' "$wt/$rel" > "$tmp"
  else
    { printf 'status: done\n'; cat "$wt/$rel"; } > "$tmp"
  fi
  cat "$tmp" > "$wt/$rel" && rm -f "$tmp" || { rm -f "$tmp"; return 1; }
  git -C "$wt" add -- "$dir" >/dev/null 2>&1 || return 1
}

# task_file_state <id> [<branch>] — what gc asks before it offers a `light/<id>-…` branch for
# deletion. `closed` only when the base branch's copy says done or dropped. `open` when the base
# copy says otherwise, or when only the branch (or this checkout) has the file: the work exists
# nowhere else. Empty when no copy exists. `unknown` when there is no base ref to read.
task_file_state() {
  local id="$1" br="${2:-}" top dir base rel c
  top="$(_tsf_top)"
  [ -n "$top" ] || { printf 'unknown\n'; return 0; }
  base="$(_tsf_base_ref)"
  [ -n "$base" ] || { printf 'unknown\n'; return 0; }
  dir="$(task_source_dir)"; rel="$dir/$id.md"
  c="$(git -C "$top" show "$base:$rel" 2>/dev/null || true)"
  if [ -n "$c" ]; then
    if _tsf_closed "$(printf '%s\n' "$c" | _tsf_field status)"; then printf 'closed\n'; else printf 'open\n'; fi
    return 0
  fi
  if [ -n "$br" ] && git -C "$top" cat-file -e "$br:$rel" 2>/dev/null; then printf 'open\n'; return 0; fi
  if [ -f "$top/$rel" ]; then printf 'open\n'; fi
  return 0
}

# task_file_share <worktree> <from-checkout> — move every draft (a task file the from-checkout has
# untracked and no branch or base copy carries) into <worktree> and stage it. Prints the ids moved.
task_file_share() {
  local wt="$1" from="$2" dir id state rest
  dir="$(task_source_dir)"
  task_file_list | while IFS="$(printf '\t')" read -r id state rest; do
    [ "$state" = draft ] || continue
    _tsf_untracked "$from" "$dir/$id.md" || continue
    mkdir -p "$wt/$dir" && cp "$from/$dir/$id.md" "$wt/$dir/$id.md" || continue
    git -C "$wt" add -- "$dir/$id.md" >/dev/null 2>&1 || continue
    rm -f "$from/$dir/$id.md"
    printf '%s\n' "$id"
  done
  rmdir "$from/$dir" 2>/dev/null || true
  return 0
}
