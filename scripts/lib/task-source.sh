#!/usr/bin/env bash
# shellcheck shell=bash
# task-source.sh — the task-source interface for light tasks (#450).
#
# A light task is a unit of work that is NOT a GitHub issue. Where its record lives is a SOURCE, and
# every reader and writer (the `cckit task` verbs in light-task.sh, the gc protection in
# worktree-issue.sh) reaches it through task_source_call — never through a source's own functions.
# One source ships: `file` (task-source-file.sh), one tracked file per task.
#
# Selecting a source: `tasks.source` in the project config (default `file`); KIT_TASKS_SOURCE in the
# environment wins per invocation.
#
# `tasks.default` is a different question — whether the project's DEFAULT list is this one (`light`)
# or GitHub issues (`issues`, the default). task_default_name answers it.
#
# Adding a source `<name>` (lowercase letters, digits, `_`): add scripts/lib/task-source-<name>.sh
# defining the functions below, then set `tasks.source` to `<name>`. Nothing else changes: the verbs,
# the branch form and the gc protection are source-independent.
#
#   task_<name>_list                      every task, one TSV row each (format below)
#   task_<name>_get <id|prefix>           the one matching row; rc 1 none, rc 3 ambiguous
#   task_<name>_create <title> <priority> <kind> <body>     record a new task; print its id
#   task_<name>_on_start <id> <worktree> <from-checkout>    work begins in <worktree>
#   task_<name>_on_finish <id> <worktree>                   work is ready for review
#   task_<name>_state <id> [<branch>]     open | closed | unknown | (empty: no such task). rc 0
#                                         always. gc keeps a branch on `open` and on `unknown`.
#   task_<name>_share <worktree> <from-checkout>   OPTIONAL: move every not-yet-shared task into
#                                         <worktree>; print one id per line. `cckit task share`
#                                         refuses when the source does not define it.
#
# TSV row: <id>\t<state>\t<priority>\t<kind>\t<created>\t<branch>\t<title>
#   state    draft (only in this checkout) · todo · doing · review · done · dropped ·
#            shared (committed by `cckit task share`, its pull request not merged yet)
#   branch   the task's `light/<id>-<slug>` ref; for `shared`, the `light/share-<stamp>` ref that
#            carries it; else `-`
# No field is ever empty (`-` is the absent marker): tab is IFS whitespace, so an empty field would
# shift the rest. The title is last and may hold spaces.
#
# An id is a lowercase letter followed by 1-11 lowercase letters or digits. The leading letter is
# what keeps a light branch from parsing as an issue number (worktree-issue.sh, wt_issue_number).
#
# Requires: git; jq for the config read (without it the defaults apply). bash 3.2 + zsh.
# errors: mixed — the dispatcher returns 2 for an unknown source or op; each op states its own

_TASK_SOURCE_LIB_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd)"

# _task_source_cfg <jq-filter> <default> — one key of the project config, or the default.
_task_source_cfg() {
  local cfg="${KIT_CONFIG:-}" top v=""
  if [ -z "$cfg" ] || [ ! -f "$cfg" ]; then
    top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    if [ -n "$top" ] && [ -f "$top/cckit.config.json" ]; then cfg="$top/cckit.config.json"
    elif [ -n "$top" ] && [ -f "$top/.claude/kit.config.json" ]; then cfg="$top/.claude/kit.config.json"
    else cfg=""; fi
  fi
  if [ -n "$cfg" ] && command -v jq >/dev/null 2>&1; then
    v="$(jq -r "$1 // empty" "$cfg" 2>/dev/null || true)"
  fi
  printf '%s' "${v:-$2}"
}

# task_source_name — the selected source.
task_source_name() {
  if [ -n "${KIT_TASKS_SOURCE:-}" ]; then printf '%s' "$KIT_TASKS_SOURCE"; return 0; fi
  _task_source_cfg '.tasks.source' file
}

# task_default_name — which task list is this project's default: `light` (the `cckit task` list) or
# `issues` (GitHub issues). `tasks.default` in the project config; anything else, or no key, is
# `issues`, with a warning for a value that is neither. `cckit next` and the campaign skill read it
# to pick their lane; both lists stay usable whatever it says.
task_default_name() {
  local v; v="$(_task_source_cfg '.tasks.default' issues)"
  case "$v" in
    light|issues) printf '%s' "$v" ;;
    *) echo "⚠ tasks.default '$v' is neither 'light' nor 'issues' — using 'issues'" >&2; printf 'issues' ;;
  esac
}

# task_source_dir — the tracked directory the file source keeps tasks in, relative to the checkout
# root (`tasks.dir`, default `tasks`; KIT_TASKS_DIR wins). A value that is absolute or climbs out
# of the checkout is ignored with a warning.
task_source_dir() {
  local d="${KIT_TASKS_DIR:-}"
  [ -n "$d" ] || d="$(_task_source_cfg '.tasks.dir' tasks)"
  d="${d%/}"
  case "$d" in
    ''|/*|..|../*|*/..|*/../*)
      echo "⚠ tasks.dir '$d' is not a path inside the project — using 'tasks'" >&2; d="tasks" ;;
  esac
  printf '%s' "$d"
}

# task_id_valid <id> — rc 0 for a usable task id. `share` is reserved: `light/share-<stamp>` is the
# branch `cckit task share` opens its pull request from.
task_id_valid() {
  case "${1:-}" in ''|[!a-z]*|*[!a-z0-9]*|share) return 1 ;; esac
  [ "${#1}" -ge 2 ] && [ "${#1}" -le 12 ]
}

# task_source_has <op> — rc 0 when the selected source defines <op>.
task_source_has() {
  local src fn
  src="$(task_source_name)"
  case "$src" in ''|*[!a-z0-9_]*) return 1 ;; esac
  fn="task_${src}_$1"
  if ! command -v "$fn" >/dev/null 2>&1 && [ -f "$_TASK_SOURCE_LIB_DIR/task-source-$src.sh" ]; then
    # shellcheck source=/dev/null
    . "$_TASK_SOURCE_LIB_DIR/task-source-$src.sh"
  fi
  command -v "$fn" >/dev/null 2>&1
}

# task_source_call <op> [args…] — run <op> on the selected source. rc 2 when the source name is not
# a name, or the source does not define the op.
task_source_call() {
  local op="${1:-}" src
  [ "$#" -gt 0 ] && shift
  src="$(task_source_name)"
  case "$src" in
    ''|*[!a-z0-9_]*) echo "✗ tasks.source '$src' is not a source name (lowercase letters, digits, _)" >&2; return 2 ;;
  esac
  if ! task_source_has "$op"; then
    echo "✗ task source '$src' has no '$op' (expected task_${src}_$op in scripts/lib/task-source-$src.sh)" >&2
    return 2
  fi
  "task_${src}_$op" "$@"
}
