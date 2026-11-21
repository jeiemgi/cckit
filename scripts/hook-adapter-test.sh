#!/usr/bin/env bash
# hook-adapter-test.sh — one set of hook scripts, two runtimes (E257.5, #262).
#
# Initializes a throwaway project with BOTH adapters, then drives each installed hook twice: once
# with the event JSON Claude Code sends (through .claude/hooks/, CLAUDE_PROJECT_DIR set) and once
# with the event JSON Codex sends (through the command registered in .codex/hooks.json, run from the
# session cwd with no CLAUDE_PROJECT_DIR). Asserts the same behavior on both:
#   - a base-branch commit is blocked with a reason; a worktree commit passes
#   - a raw `gh pr merge` is blocked; the pre-push gate reads either config location
#   - ordinary mail never blocks Stop; steer mail blocks Stop once and never twice
#   - in the combined install each message is delivered exactly once, whichever runtime asks first
#
# WHAT THIS IS NOT: the event JSON here is written from each runtime's hook documentation, not
# captured from a live session, and no agent process runs. It proves the scripts handle both
# documented shapes; it does not prove Codex fires the hooks or honours exit 2 (agent-compatibility
# .mdx records that as unverified).
# Run:  bash scripts/hook-adapter-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
t() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
has() { case "$2" in *"$3"*) echo "ok: $1" ;; *) echo "FAIL: $1 -> '[$2]' lacks '[$3]'"; fail=1 ;; esac; }
command -v jq  >/dev/null 2>&1 || { echo "SKIP: jq not available";  exit 0; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not available"; exit 0; }
# shellcheck source=/dev/null
. "$ROOT/scripts/lib/codex-hooks.sh"

tmp="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$tmp"' EXIT
export KIT_MAIL_DIR="$tmp/mail"
# The mail hook calls `cckit`; give it this checkout's, not whatever is installed on the machine.
mkdir -p "$tmp/bin"
printf '#!/usr/bin/env bash\nexec "%s/bin/cckit" "$@"\n' "$ROOT" > "$tmp/bin/cckit"; chmod +x "$tmp/bin/cckit"
PATH="$tmp/bin:$PATH"; export PATH

P="$tmp/proj"; W="$tmp/wt"
mkdir -p "$P" && git -C "$P" init -q -b main \
  && git -C "$P" config user.email kit-test@example.com && git -C "$P" config user.name kit-test \
  && git -C "$P" remote add origin git@github.com:example/fx.git   # the mailbox is keyed by the remote slug
KIT_INIT_PREFLIGHT=0 KIT_BASE_BRANCH=main CLAUDE_PLUGIN_ROOT="$ROOT" bash "$ROOT/scripts/init.sh" \
  --profile minimal --adapter both --target "$P" --repo example/fx --owner-login example >/dev/null 2>&1 </dev/null \
  || { echo "FAIL: init --adapter both exited non-zero"; exit 1; }
git -C "$P" add -A >/dev/null 2>&1 && git -C "$P" commit -q -m scaffold >/dev/null 2>&1
git -C "$P" worktree add -q -b feat/1-x "$W" main >/dev/null 2>&1 || { echo "FAIL: could not add the worktree"; exit 1; }

# ── event JSON, per runtime (documented fields) ────────────────────────────────────────────────
ev() {  # ev <claude|codex> <event> <cwd> [command | argv-json] -> the event document on stdout
  local rt="$1" e="$2" cwd="$3" cmd="${4:-}" tool='{}'
  if [ -n "$cmd" ]; then
    case "$cmd" in
      '['*) tool="$(jq -cn --argjson c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}')" ;;
      *)    tool="$(jq -cn --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}')" ;;
    esac
  fi
  if [ "$rt" = claude ]; then
    jq -cn --arg e "$e" --arg d "$cwd" --argjson t "$tool" \
      '{session_id:"s1",transcript_path:"/tmp/t.jsonl",cwd:$d,permission_mode:"default",hook_event_name:$e} + $t
       + (if $e == "Stop" then {stop_hook_active:false} else {} end)'
  else
    jq -cn --arg e "$e" --arg d "$cwd" --argjson t "$tool" \
      '{session_id:"s1",transcript_path:null,cwd:$d,hook_event_name:$e,model:"m",turn_id:"t1"} + $t
       + (if ($t | has("tool_name")) then {tool_use_id:"u1"} else {} end)
       + (if $e == "Stop" then {stop_hook_active:false,last_assistant_message:"done"} else {} end)'
  fi
}
# fire <claude|codex> <script> <event> <cwd> [command] -> runs the hook the way that runtime would.
# Sets OUT (stdout), ERR (stderr), RC.
fire() {
  local rt="$1" script="$2" e="$3" cwd="$4" cmd="${5:-}" doc
  doc="$(ev "$rt" "$e" "$cwd" "$cmd")"
  if [ "$rt" = claude ]; then
    OUT="$(cd "$cwd" && printf '%s' "$doc" | CLAUDE_PROJECT_DIR="$P" bash "$P/.claude/hooks/$script" 2>"$tmp/err")"; RC=$?
  else
    # Codex: the REGISTERED command string, from the session cwd, with no Claude variable.
    OUT="$(cd "$cwd" && printf '%s' "$doc" | env -u CLAUDE_PROJECT_DIR bash -c "$(codex_hooks_command "$script")" 2>"$tmp/err")"; RC=$?
  fi
  ERR="$(cat "$tmp/err")"
}

# ── registration ───────────────────────────────────────────────────────────────────────────────
HJ="$P/.codex/hooks.json"
t "codex: hooks.json written"             "$([ -f "$HJ" ] && echo yes || echo no)" "yes"
t "codex: no absolute machine path"       "$(grep -rlF "$tmp" "$P/.codex" 2>/dev/null | wc -l | tr -d ' ')" "0"
t "codex: no command starts at / or ~"    "$(jq -r '.hooks[][].hooks[].command' "$HJ" | grep -cE '(^|[" ])(/|~)')" "0"
t "codex: every registered script is installed in the worktree" \
  "$(jq -r '.hooks[][].hooks[].command' "$HJ" | sed 's|.*/\.codex/hooks/||; s|"$||' | sort -u | while IFS= read -r s; do [ -x "$W/.codex/hooks/$s" ] || echo "$s"; done | tr '\n' ' ')" ""
t "codex: guards on PreToolUse Bash"      "$(jq -r '[.hooks.PreToolUse[] | select(.matcher == "Bash")] | length' "$HJ")" "2"
t "codex: mail on four events"            "$(jq -r --arg c "$(codex_hooks_command kit-mail-check.sh)" '[.hooks | to_entries[] | select([.value[].hooks[].command] | index($c)) | .key] | sort | join(" ")' "$HJ")" \
  "PostToolUse SessionStart Stop UserPromptSubmit"
# shellcheck disable=SC2016
MAILCMD='bash "$CLAUDE_PROJECT_DIR/.claude/hooks/kit-mail-check.sh"'
# The mail registrations of a settings file: {event: [groups running the mail command]}.
MAILSEL='[.hooks | to_entries[] | {(.key): [.value[] | select([.hooks[].command] | index($c))]} | select(.[] | length > 0)] | add'
t "claude: mail hook installed"           "$([ -x "$P/.claude/hooks/kit-mail-check.sh" ] && echo yes || echo no)" "yes"
t "claude: mail wired on four events (tracked settings.json)" \
  "$(jq -r --arg c "$MAILCMD" '[.hooks | to_entries[] | select([.value[].hooks[].command] | index($c)) | .key] | sort | join(" ")' "$P/.claude/settings.json")" \
  "PostToolUse SessionStart Stop UserPromptSubmit"
t "claude: generated mail entries equal cckit's own .claude/settings.json" \
  "$(jq -cS --arg c "$MAILCMD" "$MAILSEL" "$P/.claude/settings.json")" \
  "$(jq -cS --arg c "$MAILCMD" "$MAILSEL" "$ROOT/.claude/settings.json")"
t "both: one mail script, two installs, same bytes" \
  "$(cmp -s "$P/.claude/hooks/kit-mail-check.sh" "$P/.codex/hooks/kit-mail-check.sh" && echo same || echo differs)" "same"

# ── base-branch commit guard ───────────────────────────────────────────────────────────────────
for rt in claude codex; do
  fire "$rt" guard-base-branch-commit.sh PreToolUse "$P" 'git commit -m x'
  t "$rt: base-branch commit blocked (exit 2)"     "$RC" "2"
  has "$rt: the block carries a reason"            "$ERR" "BLOCKED: direct commit to 'main'"
  fire "$rt" guard-base-branch-commit.sh PreToolUse "$W" 'git commit -m x'
  t "$rt: worktree commit passes"                  "$RC" "0"
  fire "$rt" guard-base-branch-commit.sh PreToolUse "$P" "git -C $W commit -m x"
  t "$rt: git -C <worktree> commit passes"         "$RC" "0"
  fire "$rt" guard-base-branch-commit.sh PreToolUse "$P" "cd $W && git commit -m x"
  t "$rt: cd <worktree> && commit passes"          "$RC" "0"
  fire "$rt" guard-base-branch-commit.sh PreToolUse "$W" "git -C $P commit -m x"
  t "$rt: git -C <base checkout> commit blocked"   "$RC" "2"
  fire "$rt" guard-base-branch-commit.sh PreToolUse "$P" 'git log --oneline'
  t "$rt: a non-commit passes"                     "$RC" "0"
  fire "$rt" guard-raw-git-ops.sh PreToolUse "$P" 'gh pr merge 3 --squash'
  t "$rt: raw gh pr merge blocked (exit 2)"        "$RC" "2"
  has "$rt: raw-git block names the verb"          "$ERR" "cckit merge"
  fire "$rt" guard-raw-git-ops.sh PreToolUse "$P" 'gh pr view 3'
  t "$rt: read-only gh passes"                     "$RC" "0"
  fire "$rt" repo-hygiene.sh SessionStart "$W"
  t "$rt: repo-hygiene never fails the session"    "$RC" "0"
  fire "$rt" kit_version_check.sh SessionStart "$W"
  t "$rt: version check never fails the session"   "$RC" "0"
done
# An argv-array command (a shell tool may send one) is still read.
fire codex guard-base-branch-commit.sh PreToolUse "$P" '["bash","-lc","git commit -m x"]'
t "codex: argv-array command blocked on the base branch" "$RC" "2"
fire codex guard-raw-git-ops.sh PreToolUse "$P" '["bash","-lc","gh pr merge 3"]'
t "codex: argv-array raw merge blocked"            "$RC" "2"
# The event cwd beats CLAUDE_PROJECT_DIR (always the main checkout): a session sitting in a worktree
# commits without naming a directory, and is not false-blocked.
OUT="$(cd "$W" && ev claude PreToolUse "$W" 'git commit -m x' | CLAUDE_PROJECT_DIR="$P" bash "$P/.claude/hooks/guard-base-branch-commit.sh" 2>/dev/null)"
t "claude: event cwd wins over CLAUDE_PROJECT_DIR" "$?" "0"

# ── pre-push gate: either config location ──────────────────────────────────────────────────────
GATE="$ROOT/templates/hooks/prepush_gate.sh.tmpl"
gate() {  # gate <runtime> <dir> <command> -> the .continue value
  ( cd "$2" && ev "$1" PreToolUse "$2" "$3" | bash "$GATE" 2>/dev/null ) | jq -r '.continue'
}
cx="$tmp/codex-only"; mkdir -p "$cx"
printf '{"adapters":["codex"],"prePush":{"enabled":true,"command":"false"}}\n' > "$cx/cckit.config.json"
cl="$tmp/claude-only"; mkdir -p "$cl/.claude"
printf '{"prePush":{"enabled":true,"command":"false"}}\n' > "$cl/.claude/kit.config.json"
t "codex-only: failing check stops the push (root config)" "$(gate codex "$cx" 'git push origin x')" "false"
t "claude: failing check stops the push"                   "$(gate claude "$cl" 'git push origin x')" "false"
t "codex-only: a non-push passes"                          "$(gate codex "$cx" 'git status')" "true"
t "codex-only: argv-array push is gated"                   "$(gate codex "$cx" '["bash","-lc","git push origin x"]')" "false"
printf '{"adapters":["codex"],"prePush":{"enabled":true,"command":"true"}}\n' > "$cx/cckit.config.json"
t "codex-only: passing check lets the push through"        "$(gate codex "$cx" 'git push origin x')" "true"

# ── session mail ───────────────────────────────────────────────────────────────────────────────
send() { ( cd "$P" && cckit msg send "$@" >/dev/null 2>&1 ); }
ctx()  { printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null; }

for first in claude codex; do
  if [ "$first" = claude ]; then second=codex; else second=claude; fi
  # ordinary mail: never blocks Stop, delivered once
  send feat/1-x "note for $first"
  fire "$first"  kit-mail-check.sh Stop "$W";  t "$first first: ordinary mail does not block Stop"  "$OUT" ""
  fire "$second" kit-mail-check.sh Stop "$W";  t "$second second: ordinary mail does not block Stop" "$OUT" ""
  fire "$first"  kit-mail-check.sh PostToolUse "$W" 'ls'
  has "$first first: ordinary mail delivered between tool calls" "$(ctx)" "note for $first"
  t   "$first first: delivery names its event" "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.hookEventName')" "PostToolUse"
  fire "$second" kit-mail-check.sh PostToolUse "$W" 'ls'
  t "$second second: the same message is not delivered again" "$OUT" ""
  fire "$second" kit-mail-check.sh UserPromptSubmit "$W"
  t "$second second: nor on the next prompt" "$OUT" ""

  # steer mail: blocks Stop once, never twice, in either runtime
  send feat/1-x --steer "steer for $first"
  fire "$first" kit-mail-check.sh Stop "$W"
  t   "$first first: steer blocks Stop"            "$(printf '%s' "$OUT" | jq -r '.decision')" "block"
  has "$first first: the block reason is the mail" "$(printf '%s' "$OUT" | jq -r '.reason')" "steer for $first"
  fire "$first"  kit-mail-check.sh Stop "$W";  t "$first first: the second Stop is not blocked"       "$OUT" ""
  fire "$second" kit-mail-check.sh Stop "$W";  t "$second second: Stop is not blocked by the same steer" "$OUT" ""
  fire "$second" kit-mail-check.sh SessionStart "$W"; t "$second second: steer is not re-delivered at start" "$OUT" ""
done
# cold start + next prompt deliver in both, and the session in the main checkout is a different mailbox
for rt in claude codex; do
  send feat/1-x "cold $rt"
  fire "$rt" kit-mail-check.sh SessionStart "$P";    t "$rt: another branch's mail is not delivered here" "$OUT" ""
  fire "$rt" kit-mail-check.sh SessionStart "$W";    has "$rt: SessionStart delivers" "$(ctx)" "cold $rt"
  send feat/1-x "prompt $rt"
  fire "$rt" kit-mail-check.sh UserPromptSubmit "$W"; has "$rt: UserPromptSubmit delivers" "$(ctx)" "prompt $rt"
done
t "nothing left unread"  "$(find "$KIT_MAIL_DIR" -path '*/new/*' -type f | wc -l | tr -d ' ')" "0"

[ "$fail" -eq 0 ] && echo "ALL OK (hook-adapter)"
exit "$fail"
