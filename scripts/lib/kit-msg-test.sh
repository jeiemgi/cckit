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

# ── hcom-informed hardening (#175): cap, typo warning, opt-in Stop long-poll ────────────────────
# delivery cap: excess mail rides the NEXT hook fire, nothing is lost
cd "$tmp/appA"
msg_send "docs/site" "one" >/dev/null 2>&1
msg_send "docs/site" "two" >/dev/null 2>&1
cd "$tmp/appA-docs"
# order within one second is filename-random — assert counts and the union, not sequence
h1="$(KIT_MAIL_MAX_PER_DELIVERY=1 msg_hook_check PostToolUse | jq -r '.hookSpecificOutput.additionalContext')"
h2="$(KIT_MAIL_MAX_PER_DELIVERY=1 msg_hook_check PostToolUse | jq -r '.hookSpecificOutput.additionalContext')"
t "cap: first delivery carries exactly one message"  "$(printf '%s' "$h1" | grep -c '^kind: note')" "1"
t "cap: second delivery carries exactly one message" "$(printf '%s' "$h2" | grep -c '^kind: note')" "1"
case "$h1$h2" in
  *one*two*|*two*one*) echo "ok: capped-out mail rides the next hook fire (nothing lost)" ;;
  *) echo "FAIL: cap lost mail: [$h1] [$h2]"; fail=1 ;;
esac

# typo'd target → loud warning about a brand-new mailbox
cd "$tmp/appA"
warn="$(msg_send "task/9-fxi" "typo target" 2>&1 >/dev/null)"
case "$warn" in *"new mailbox"*) echo "ok: unknown target warns instead of silently dropping" ;; *) echo "FAIL: no new-mailbox warning: $warn"; fail=1 ;; esac
warn="$(msg_send "task/9-fix" "known target" 2>&1 >/dev/null)"
case "$warn" in *"new mailbox"*) echo "FAIL: warned on an existing mailbox"; fail=1 ;; *) echo "ok: existing mailbox does not warn" ;; esac

# opt-in Stop long-poll: steer sent DURING the wait is still delivered (near-real-time idle steer)
cd "$tmp/appA-docs"
( sleep 1; cd "$tmp/appA" && . "$LIB/kit-msg.sh" && msg_send "docs/site" --steer "late steer" >/dev/null 2>&1 ) &
pj="$(KIT_MAIL_STOP_POLL=4 msg_hook_check Stop)"
wait
case "$(printf '%s' "$pj" | jq -r '.reason' 2>/dev/null)" in
  *"late steer"*) echo "ok: Stop long-poll catches a steer that lands mid-wait" ;;
  *) echo "FAIL: long-poll missed the steer: $pj"; fail=1 ;;
esac
t "long-poll consumed the steer (no double block)" "$(msg_hook_check Stop)" ""

[ "$fail" -eq 0 ] && echo "ALL OK (kit-msg)"
exit "$fail"
