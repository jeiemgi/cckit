#!/usr/bin/env bash
# shellcheck shell=bash
# codex-hooks-test.sh — the .codex/hooks.json merge (E257.5, #262): cckit's registrations go in, the
# user's stay, a second run changes nothing, and a file that is not a hooks.json is refused untouched.
# Run under bash and zsh. Run:  bash scripts/lib/codex-hooks-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
set -u
LIB="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$LIB/../.." && pwd)"
command -v jq >/dev/null 2>&1 || { echo "codex-hooks-test: jq required" >&2; exit 1; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/body.sh" <<'BODY'
fail=0
t() { if [ "$2" = "$3" ]; then echo "ok($SH): $1"; else echo "FAIL($SH): $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
. "$LIB/codex-hooks.sh"
TPL="$ROOT/templates/codex/hooks.json.tmpl"
w="$tmp/$SH"; mkdir -p "$w"

# --- the command string ------------------------------------------------------------------------
t "command is checkout-relative" "$(codex_hooks_command kit-mail-check.sh)" \
  'bash "$(git rev-parse --show-toplevel)/.codex/hooks/kit-mail-check.sh"'
t "template is valid JSON" "$(jq -e . "$TPL" >/dev/null 2>&1 && echo yes || echo no)" "yes"
t "template commands are all checkout-relative" \
  "$(jq -r '.hooks[][].hooks[].command' "$TPL" | grep -vc '^bash "\$(git rev-parse --show-toplevel)/\.codex/hooks/[a-z_-]*\.sh"$')" "0"
t "template registers the five events" "$(jq -r '.hooks | keys | join(" ")' "$TPL")" \
  "PostToolUse PreToolUse SessionStart Stop UserPromptSubmit"
t "template: every registered script has a hook template" \
  "$(jq -r '.hooks[][].hooks[].command' "$TPL" | sed 's|.*/\.codex/hooks/||; s|"$||' | sort -u | while IFS= read -r s; do [ -f "$ROOT/templates/hooks/$s.tmpl" ] || echo "$s"; done | tr '\n' ' ')" ""

# --- create ------------------------------------------------------------------------------------
t "no file: created"            "$(codex_hooks_merge "$w/a.json" "$TPL")" "created"
t "created file equals template" "$(jq -S . "$w/a.json")" "$(jq -S . "$TPL")"
before="$(cat "$w/a.json")"; touch -t 200001010000 "$w/a.json"; stamp="$(ls -l "$w/a.json")"
t "second run: unchanged"       "$(codex_hooks_merge "$w/a.json" "$TPL")" "unchanged"
t "unchanged run did not rewrite the file" "$(ls -l "$w/a.json")" "$stamp"
t "unchanged run kept the bytes" "$(cat "$w/a.json")" "$before"

# --- merge into a user's file ------------------------------------------------------------------
cat > "$w/u.json" <<'JSON'
{
  "note": "mine",
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [ { "type": "command", "command": "/usr/bin/python3 my_policy.py", "timeout": 30, "statusMessage": "mine" } ] }
    ],
    "SubagentStop": [ { "hooks": [ { "type": "command", "command": "echo done" } ] } ]
  }
}
JSON
t "user file: merged"            "$(codex_hooks_merge "$w/u.json" "$TPL")" "merged"
t "user's handler kept, first"   "$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$w/u.json")" "/usr/bin/python3 my_policy.py"
t "user's handler fields kept"   "$(jq -r '.hooks.PreToolUse[0].hooks[0].statusMessage' "$w/u.json")" "mine"
t "user's other event kept"      "$(jq -r '.hooks.SubagentStop[0].hooks[0].command' "$w/u.json")" "echo done"
t "unknown top-level key kept"   "$(jq -r '.note' "$w/u.json")" "mine"
t "kit guards appended"          "$(jq '.hooks.PreToolUse | length' "$w/u.json")" "3"
t "registered: commit guard"     "$(codex_hooks_registered "$w/u.json" guard-base-branch-commit.sh && echo yes || echo no)" "yes"
t "registered: mail"             "$(codex_hooks_registered "$w/u.json" kit-mail-check.sh && echo yes || echo no)" "yes"
t "not registered: unknown"      "$(codex_hooks_registered "$w/u.json" nope.sh && echo yes || echo no)" "no"
t "not registered: no file"      "$(codex_hooks_registered "$w/absent.json" kit-mail-check.sh && echo yes || echo no)" "no"
t "merge twice: unchanged"       "$(codex_hooks_merge "$w/u.json" "$TPL")" "unchanged"
t "no duplicate mail handler"    "$(jq '[.hooks.Stop[].hooks[].command] | length' "$w/u.json")" "1"

# A handler the user already registered themselves (in their own group) is not registered twice.
jq -n --arg c "$(codex_hooks_command kit-mail-check.sh)" \
  '{hooks:{Stop:[{hooks:[{type:"command",command:$c,timeout:99}]}]}}' > "$w/own.json"
codex_hooks_merge "$w/own.json" "$TPL" >/dev/null
t "existing registration not duplicated" "$(jq '[.hooks.Stop[].hooks[]] | length' "$w/own.json")" "1"
t "existing registration keeps its timeout" "$(jq '.hooks.Stop[0].hooks[0].timeout' "$w/own.json")" "99"

# --- an opt-in fragment ------------------------------------------------------------------------
codex_hooks_fragment PreToolUse Bash prepush_gate.sh 120 > "$w/frag.json"
t "fragment: matcher + timeout" "$(jq -c '.hooks.PreToolUse[0] | [.matcher, .hooks[0].timeout]' "$w/frag.json")" '["Bash",120]'
t "fragment: no matcher key when empty" \
  "$(codex_hooks_fragment SessionStart "" kit-local-status.sh 10 | jq -c '.hooks.SessionStart[0] | has("matcher")')" "false"
t "fragment merges"             "$(codex_hooks_merge "$w/a.json" "$w/frag.json")" "merged"
t "fragment registered"         "$(codex_hooks_registered "$w/a.json" prepush_gate.sh && echo yes || echo no)" "yes"

# --- refusals leave the file alone -------------------------------------------------------------
printf 'not json {\n' > "$w/bad.json"
codex_hooks_merge "$w/bad.json" "$TPL" >/dev/null 2>&1; t "invalid JSON refused (rc)" "$?" "1"
t "invalid JSON left untouched" "$(cat "$w/bad.json")" "not json {"
printf '[1,2]\n' > "$w/arr.json"
codex_hooks_merge "$w/arr.json" "$TPL" >/dev/null 2>&1; t "non-object refused (rc)" "$?" "1"
t "non-object left untouched"   "$(cat "$w/arr.json")" "[1,2]"
printf '{"hooks":[]}\n' > "$w/h.json"
codex_hooks_merge "$w/h.json" "$TPL" >/dev/null 2>&1; t "hooks-as-array refused (rc)" "$?" "1"
t "no temp file left behind"    "$(ls "$w" | grep -c '\.tmp$')" "0"
[ "$fail" -eq 0 ] && echo "ALL OK($SH)"
exit "$fail"
BODY

rc=0
SH=bash LIB="$LIB" ROOT="$ROOT" tmp="$tmp" bash "$tmp/body.sh" || rc=1
if command -v zsh >/dev/null 2>&1; then
  SH=zsh LIB="$LIB" ROOT="$ROOT" tmp="$tmp" zsh "$tmp/body.sh" || rc=1
else
  echo "skip: zsh not installed"
fi
exit "$rc"
