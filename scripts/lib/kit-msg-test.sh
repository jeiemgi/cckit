#!/usr/bin/env bash
# shellcheck shell=bash
# kit-msg-test.sh — #175: session mail. Hermetic: KIT_MAIL_DIR pins the mailbox root; two
# throwaway repos (with remotes) stand in for two PROJECTS, worktrees for sessions. Covers:
# send/read-once, CROSS-PROJECT addressing (project:branch), broadcast seen-ledger (each
# recipient exactly once, project-scoped), steer marking, and the hook driver's per-event JSON
# (additionalContext events vs the Stop block that fires ONLY for steer mail and never twice).
# Run:  bash scripts/lib/kit-msg-test.sh
set -u
LIB="$(cd "$(dirname "$0")" && pwd)"
fail=0
t() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
command -v jq >/dev/null 2>&1 || { echo "kit-msg-test: jq required" >&2; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export KIT_MAIL_DIR="$tmp/mail"

mkrepo() { # mkrepo <dir> <owner/name>
  git -C "$tmp" init -q -b main "$1"
  git -C "$tmp/$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  git -C "$tmp/$1" remote add origin "git@github.com:$2.git"
}
mkrepo appA "acme/app-a"
mkrepo appB "acme/app-b"
git -C "$tmp/appA" worktree add -q -b task/9-fix "$tmp/appA-fix"  main >/dev/null 2>&1
git -C "$tmp/appA" worktree add -q -b docs/site  "$tmp/appA-docs" main >/dev/null 2>&1

# shellcheck source=/dev/null
. "$LIB/kit-msg.sh"

# ── same-project: send (from main) → read-once (in task/9-fix) ─────────────────────────────────
cd "$tmp/appA"
msg_send "task/9-fix" "rebase onto main" >/dev/null 2>&1
t "mailbox is keyed project/branch (encoded)" \
  "$(ls "$KIT_MAIL_DIR/acme+app-a/task+9-fix/new" | wc -l | tr -d ' ')" "1"

cd "$tmp/appA-fix"
out="$(msg_read)"
case "$out" in *"rebase onto main"*) echo "ok: recipient reads the message" ;; *) echo "FAIL: read output: $out"; fail=1 ;; esac
t "direct mail is read-ONCE (moved to read/)" "$(msg_read)" "no mail for acme/app-a:task/9-fix"
t "consumed mail is archived, not lost" \
  "$(ls "$KIT_MAIL_DIR/acme+app-a/task+9-fix/read" | wc -l | tr -d ' ')" "1"

# ── cross-project: appB steers appA's docs session by project:branch ────────────────────────────
cd "$tmp/appB"
msg_send "acme/app-a:docs/site" "app-b broke your API fixture" >/dev/null 2>&1
cd "$tmp/appA-docs"
out="$(msg_read)"
case "$out" in *"app-b broke your API fixture"*) echo "ok: cross-project mail delivered" ;; *) echo "FAIL: cross-project: $out"; fail=1 ;; esac
case "$out" in *"from: main (acme/app-b)"*) echo "ok: sender carries its project identity" ;; *) echo "FAIL: sender header: $out"; fail=1 ;; esac

# ── broadcast: project-scoped, each session exactly once ────────────────────────────────────────
cd "$tmp/appA"
msg_send all "v0.4.0 released" >/dev/null 2>&1
cd "$tmp/appA-fix";  out1="$(msg_read)"
cd "$tmp/appA-docs"; out2="$(msg_read)"
case "$out1" in *"v0.4.0 released"*) echo "ok: broadcast reaches session 1" ;; *) echo "FAIL: bcast s1: $out1"; fail=1 ;; esac
case "$out2" in *"v0.4.0 released"*) echo "ok: broadcast reaches session 2" ;; *) echo "FAIL: bcast s2: $out2"; fail=1 ;; esac
t "broadcast is once per session" "$(msg_read)" "no mail for acme/app-a:docs/site"
cd "$tmp/appB"
t "broadcast is project-scoped (app-b unaffected)" "$(msg_read)" "no mail for acme/app-b:main"

# ── hook driver: additionalContext events ───────────────────────────────────────────────────────
cd "$tmp/appA"
msg_send "docs/site" "please hold merges" >/dev/null 2>&1
cd "$tmp/appA-docs"
hj="$(msg_hook_check PostToolUse)"
t "PostToolUse JSON names the event" "$(printf '%s' "$hj" | jq -r '.hookSpecificOutput.hookEventName')" "PostToolUse"
case "$(printf '%s' "$hj" | jq -r '.hookSpecificOutput.additionalContext')" in
  *"please hold merges"*) echo "ok: mail rides additionalContext" ;;
  *) echo "FAIL: additionalContext: $hj"; fail=1 ;;
esac
t "hook is SILENT with no mail" "$(msg_hook_check PostToolUse)" ""

# ── Stop: blocks only for steer mail, consumed so it can never block twice ─────────────────────
cd "$tmp/appA"
msg_send "docs/site" "fyi only" >/dev/null 2>&1
cd "$tmp/appA-docs"
t "Stop ignores a plain note" "$(msg_hook_check Stop)" ""
cd "$tmp/appB"
msg_send "acme/app-a:docs/site" --steer "stop and rebase first" >/dev/null 2>&1
cd "$tmp/appA-docs"
sj="$(msg_hook_check Stop)"
t "Stop blocks for steer mail (cross-project too)" "$(printf '%s' "$sj" | jq -r '.decision')" "block"
case "$(printf '%s' "$sj" | jq -r '.reason')" in
  *"stop and rebase first"*) echo "ok: steer text is the block reason" ;;
  *) echo "FAIL: stop reason: $sj"; fail=1 ;;
esac
t "a consumed steer never blocks twice" "$(msg_hook_check Stop)" ""
# the plain note from above is still queued for a context event
case "$(msg_hook_check UserPromptSubmit)" in
  *"fyi only"*) echo "ok: note still delivered on the next context event" ;;
  *) echo "FAIL: note lost after Stop pass"; fail=1 ;;
esac

[ "$fail" -eq 0 ] && echo "ALL OK (kit-msg)"
exit "$fail"
