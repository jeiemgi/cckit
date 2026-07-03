#!/usr/bin/env bash
# shellcheck shell=bash
# kit-msg.sh — session mail (#175): a MACHINE-GLOBAL filesystem mailbox so parallel sessions reach
# each other mid-flight — across projects or within one — instead of waiting for a resume.
# Delivery is hook-driven (see templates/hooks/kit-mail-check.sh.tmpl): PostToolUse injects unread
# mail between a working session's tool calls (the steer), UserPromptSubmit/SessionStart cover
# human-driven and cold-start delivery, and Stop blocks a finishing session ONLY for unread
# --steer messages.
#
#   msg_send <target> [--steer] <text…>   target: <branch> | all (this project)
#                                                  <owner/repo>:<branch> | <owner/repo>:all
#   msg_read [--peek]                      print + consume this session's unread mail
#   msg_list                               inventory of every mailbox on this machine
#   msg_hook_check <event>                 hook driver: emit the event's JSON (silent = no mail)
#
# Identity: a session is (project, branch) — project from the git remote slug (owner/repo, the
# git-remote.sh resolver), branch from HEAD. State lives at ~/.cckit/mail/<project>/<branch>
# (override root with KIT_MAIL_DIR; "/" encoded as "+" — the worktree-dir precedent). A direct
# message is read-ONCE (new/ → read/); a broadcast (`all`) is project-scoped, hits each session
# exactly once via a per-branch seen ledger, and expires after 7 days.

# Lazily bring in the shared remote-slug resolver (no-op if the caller already sourced it).
_msg_source_remote() {
  command -v git_remote_slug >/dev/null 2>&1 && return 0
  local d; d="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
  # shellcheck source=/dev/null
  [ -f "$d/git-remote.sh" ] && . "$d/git-remote.sh"
}

_msg_home()   { printf '%s' "${KIT_MAIL_DIR:-$HOME/.cckit/mail}"; }
_msg_encode() { printf '%s' "$1" | tr '/' '+'; }

# The invoking session's project id: the remote slug (owner/repo), else the toplevel dir name.
_msg_proj() {
  _msg_source_remote
  local s=""
  command -v git_remote_slug >/dev/null 2>&1 && s="$(git_remote_slug "$PWD" 2>/dev/null || true)"
  [ -n "$s" ] || s="$(basename "$(git rev-parse --show-toplevel 2>/dev/null || echo no-project)")"
  printf '%s' "$s"
}
_msg_branch() { git rev-parse --abbrev-ref HEAD 2>/dev/null; }

# _msg_parse <target> — split "[project:]branch-or-all" into PROJ + BOX (current project default).
_msg_parse() {
  case "$1" in
    *:*) _MSG_PROJ="${1%%:*}"; _MSG_BOX="${1#*:}" ;;
    *)   _MSG_PROJ="$(_msg_proj)"; _MSG_BOX="$1" ;;
  esac
  [ -n "$_MSG_PROJ" ] && [ -n "$_MSG_BOX" ]
}

# msg_send <target> [--steer] <text…>
msg_send() {
  local target="${1:-}"; shift || true
  local steer=0
  [ "${1:-}" = "--steer" ] && { steer=1; shift; }
  local text="$*"
  [ -n "$target" ] && [ -n "$text" ] || { echo 'msg_send: usage: cckit msg send <branch|all|project:branch|project:all> [--steer] "<text>"' >&2; return 1; }
  _msg_parse "$target" || { echo "msg_send: bad target '$target'" >&2; return 1; }
  local from_proj from_branch
  from_proj="$(_msg_proj)"; from_branch="$(_msg_branch)"; from_branch="${from_branch:-unknown}"
  local box="$(_msg_home)/$(_msg_encode "$_MSG_PROJ")/$(_msg_encode "$_MSG_BOX")/new"
  # A typo'd target would silently create a dead mailbox (hcom hard-fails here; we warn) — flag a
  # first-time mailbox so a misaddressed steer doesn't just vanish.
  [ -d "$(dirname "$box")" ] || [ "$_MSG_BOX" = "all" ] \
    || echo "  ⚠ new mailbox $_MSG_PROJ:$_MSG_BOX — no session has mail here yet; check the target if you expected one (cckit msg list)" >&2
  mkdir -p "$box" || return 1
  local kind="note"; [ "$steer" = 1 ] && kind="steer"
  # epoch-$$ alone collides for two sends in the same second from one shell — the second message
  # would silently OVERWRITE the first. $RANDOM + an existence check makes the name unique.
  local f
  while :; do
    f="$box/$(date +%s)-$$-${RANDOM}-$kind-from-$(_msg_encode "$from_proj")~$(_msg_encode "$from_branch").md"
    [ -e "$f" ] || break
  done
  {
    printf -- '---\nfrom: %s (%s)\nto: %s:%s\nkind: %s\nsent: %s\n---\n' \
      "$from_branch" "$from_proj" "$_MSG_PROJ" "$_MSG_BOX" "$kind" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '%s\n' "$text"
  } > "$f" || return 1
  echo "  ✓ mail → $_MSG_PROJ:$_MSG_BOX ($kind): $(printf '%.60s' "$text")" >&2
}

# _msg_gc — prune this project's broadcasts older than 7 days (stale ledger entries are harmless).
_msg_gc() {
  local d="$(_msg_home)/$(_msg_encode "$(_msg_proj)")/all/new"
  [ -d "$d" ] || return 0
  find "$d" -name '*.md' -type f -mtime +7 -delete 2>/dev/null || true
}

# _msg_unread — this session's unread message files (direct new/ + unseen broadcasts), one path
# per line, oldest first. Consuming is the caller's job (_msg_consume).
_msg_unread() {
  _msg_gc
  local proj branch pdir seen f base
  proj="$(_msg_encode "$(_msg_proj)")"; branch="$(_msg_encode "$(_msg_branch)")"
  [ -n "$branch" ] || return 0
  pdir="$(_msg_home)/$proj"
  [ -d "$pdir" ] || return 0
  # direct
  ls "$pdir/$branch/new"/*.md 2>/dev/null
  # broadcast: anything in all/new not yet in this branch's seen ledger
  seen="$pdir/.seen/$branch"
  for f in "$pdir/all/new"/*.md; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"
    [ -f "$seen" ] && grep -qxF "$base" "$seen" && continue
    printf '%s\n' "$f"
  done
}

# _msg_consume <file> — mark one message delivered: direct → moved to read/, broadcast → ledgered.
_msg_consume() {
  local f="$1" pdir branch
  pdir="$(_msg_home)/$(_msg_encode "$(_msg_proj)")"; branch="$(_msg_encode "$(_msg_branch)")"
  case "$f" in
    "$pdir/all/new/"*)
      mkdir -p "$pdir/.seen"
      printf '%s\n' "$(basename "$f")" >> "$pdir/.seen/$branch" ;;
    *)
      mkdir -p "$(dirname "$f")/../read"
      mv "$f" "$(dirname "$f")/../read/" 2>/dev/null || true ;;
  esac
}

# msg_read [--peek] — print unread mail; consume unless --peek.
msg_read() {
  local peek=0; [ "${1:-}" = "--peek" ] && peek=1
  local any=0 f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    any=1
    echo "── $(basename "$f")"
    cat "$f"
    [ "$peek" = 1 ] || _msg_consume "$f"
  done <<EOF_UNREAD
$(_msg_unread)
EOF_UNREAD
  [ "$any" = 1 ] || echo "no mail for $(_msg_proj):$(_msg_branch)"
}

# msg_list — machine-wide inventory (unread counts per project:mailbox).
msg_list() {
  local home d n proj
  home="$(_msg_home)"
  [ -d "$home" ] || { echo "no mail yet"; return 0; }
  for d in "$home"/*/*/new; do
    [ -d "$d" ] || continue
    n="$(ls "$d"/*.md 2>/dev/null | wc -l | tr -d ' ')"
    proj="$(basename "$(dirname "$(dirname "$d")")")"
    [ "$n" -gt 0 ] && echo "  $proj:$(basename "$(dirname "$d")"): $n unread"
  done
  return 0
}

# _msg_json_escape — minimal JSON string escaping (jq when present, sed fallback).
_msg_json_escape() {
  if command -v jq >/dev/null 2>&1; then jq -Rs . ; else
    sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | awk 'BEGIN{printf "\""} {printf "%s\\n", $0} END{printf "\""}'
  fi
}

# msg_hook_check <event> — the hook driver. Silent (exit 0, no output) when there is no mail, so
# the hook adds zero noise on the hot path. With mail, emits the event's JSON:
#   PostToolUse | UserPromptSubmit | SessionStart | PreToolUse → hookSpecificOutput.additionalContext
#   Stop → decision:block with the mail as reason — ONLY for steer-marked mail (a note never traps
#          a finishing session). KIT_MAIL_STOP_POLL=<seconds> (default 0) makes the Stop pass WAIT
#          that long for a steer to arrive before letting the session end — near-real-time steering
#          of an idle session, no daemon (the hcom long-poll trick, opt-in).
# Ordering: the JSON is emitted BEFORE the mail is consumed — a hook killed mid-run redelivers
# instead of losing the message (at-least-once, like hcom's two-phase ack). Delivery is capped at
# KIT_MAIL_MAX_PER_DELIVERY (default 20) messages per injection; the rest ride the next hook fire.
msg_hook_check() {
  local event="${1:-}" f body="" steer_only=0 count=0 max="${KIT_MAIL_MAX_PER_DELIVERY:-20}"
  [ -n "$event" ] || { echo "msg_hook_check: <event> required" >&2; return 1; }
  [ "$event" = "Stop" ] && steer_only=1

  _msg_hook_pick() {  # fill _MSG_PICKED + body from current unread (respects steer filter + cap)
    _MSG_PICKED=""
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      [ "$count" -lt "$max" ] || break
      if [ "$steer_only" = 1 ]; then
        case "$(basename "$f")" in *-steer-from-*) : ;; *) continue ;; esac
      fi
      body="$body$(cat "$f")
"
      _MSG_PICKED="$_MSG_PICKED$f
"
      count=$((count + 1))
    done <<EOF_UNREAD
$(_msg_unread)
EOF_UNREAD
  }

  _msg_hook_pick
  # Opt-in Stop long-poll: no steer yet → wait up to KIT_MAIL_STOP_POLL seconds for one to land.
  if [ "$count" -eq 0 ] && [ "$event" = "Stop" ] && [ "${KIT_MAIL_STOP_POLL:-0}" -gt 0 ] 2>/dev/null; then
    local waited=0
    while [ "$count" -eq 0 ] && [ "$waited" -lt "${KIT_MAIL_STOP_POLL}" ]; do
      sleep 1; waited=$((waited + 1)); _msg_hook_pick
    done
  fi
  [ "$count" -gt 0 ] || return 0

  local msg="SESSION MAIL (cckit msg): a parallel session sent you the message(s) below. If one is kind: steer, act on it BEFORE continuing your current plan.
$body"
  local esc; esc="$(printf '%s' "$msg" | _msg_json_escape)"
  if [ "$event" = "Stop" ]; then
    printf '{"decision":"block","reason":%s}\n' "$esc"
  else
    printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":%s}}\n' "$event" "$esc"
  fi
  # consume AFTER emit (see header) — read the picked list back without a subshell.
  while IFS= read -r f; do
    [ -n "$f" ] && _msg_consume "$f"
  done <<EOF_PICKED
$_MSG_PICKED
EOF_PICKED
}
