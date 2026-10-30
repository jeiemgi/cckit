#!/usr/bin/env bash
# guard-raw-git-ops-test.sh — end-to-end test of the raw-git guard hook (#364): feed it the
# PreToolUse JSON Claude Code sends, in a throwaway cckit repo and a non-cckit repo.
# Run: bash scripts/guard-raw-git-ops-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/templates/hooks/guard-raw-git-ops.sh.tmpl"
fail=0
t() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
command -v jq >/dev/null 2>&1 || { echo "guard-raw-git-ops-test: jq required" >&2; exit 1; }

bash "$HOOK" --selftest >/dev/null || { echo "FAIL: classifier self-test (run: bash $HOOK --selftest)"; fail=1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
kit="$tmp/kit"; plain="$tmp/plain"
for r in "$kit" "$plain"; do
  git init -q -b develop "$r" && git -C "$r" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
done
mkdir -p "$kit/.claude"; printf '{"github":{"baseBranch":"develop"}}\n' > "$kit/.claude/kit.config.json"

run() {  # <cwd> <command> -> echoes the hook's exit code
  jq -n --arg c "$2" --arg d "$1" '{tool_input:{command:$c},cwd:$d}' | bash "$HOOK" >/dev/null 2>&1
  echo $?
}

t "blocks gh issue create in a cckit repo"        "$(run "$kit" 'gh issue create -t x -b y')" 2
t "blocks gh pr create in a cckit repo"           "$(run "$kit" 'gh pr create --fill')" 2
t "blocks gh pr merge in a cckit repo"            "$(run "$kit" 'gh pr merge 3 --squash')" 2
t "blocks gh issue close in a cckit repo"         "$(run "$kit" 'gh issue close 3')" 2
t "blocks git checkout -b on the base branch"     "$(run "$kit" 'git checkout -b feat/1-x')" 2
t "allows read-only gh"                           "$(run "$kit" 'gh pr view 3 --json body')" 0
t "allows the verbs"                              "$(run "$kit" 'cckit pr 3 "summary"')" 0
t "ignores a repo with no cckit config"           "$(run "$plain" 'gh pr create --fill')" 0
t "resolves the repo from cd <dir>"               "$(run "$plain" "cd $kit && gh pr create --fill")" 2

git -C "$kit" checkout -q -b feat/1-x
t "allows a branch cut off a non-base branch"     "$(run "$kit" 'git checkout -b scratch')" 0
git -C "$kit" checkout -q develop

out="$(jq -n --arg c 'gh issue create -t x' --arg d "$kit" '{tool_input:{command:$c},cwd:$d}' | bash "$HOOK" 2>&1)"
case "$out" in *"cckit new --role"*) echo "ok: the block names the verb to run" ;; *) echo "FAIL: no verb hint in: $out"; fail=1 ;; esac

t "KIT_ALLOW_RAW=1 lets one command through"     "$(run "$kit" 'KIT_ALLOW_RAW=1 gh pr create --fill')" 0
t "the bypass is recorded"                        "$(grep -c 'pr-create' "$kit/.git/cckit/raw-bypass.log" 2>/dev/null)" 1

# ── init / init --upgrade wire the guard into the TRACKED settings.json, once ─────────────────
proj="$tmp/proj"
git init -q "$proj" && git -C "$proj" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
mkdir -p "$proj/.claude"
printf '{"kitVersion":"0.0.1","profile":"software","project":{"name":"G","slug":"g"},"github":{"repo":"e/g","owner":"e","projectsV2":false}}\n' > "$proj/.claude/kit.config.json"
# a project's own PreToolUse hooks must survive the merge
printf '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"own-guard.sh"}]}]}}\n' > "$proj/.claude/settings.json"
for _ in 1 2; do
  CLAUDE_PLUGIN_ROOT="$ROOT" bash "$ROOT/scripts/init.sh" --upgrade --target "$proj" --force >/dev/null 2>&1 \
    || { echo "FAIL: init.sh --upgrade exited non-zero"; fail=1; }
done
S="$proj/.claude/settings.json"
t "init --upgrade copies the hook"               "$([ -x "$proj/.claude/hooks/guard-raw-git-ops.sh" ] && echo yes)" yes
t "the guard is wired exactly once (2 upgrades)" "$(jq '[.hooks.PreToolUse[].hooks[] | select(.command | endswith("guard-raw-git-ops.sh"))] | length' "$S")" 1
t "the wiring uses \$CLAUDE_PROJECT_DIR"         "$(jq -r '[.hooks.PreToolUse[].hooks[].command | select(endswith("guard-raw-git-ops.sh"))][0]' "$S")" '$CLAUDE_PROJECT_DIR/.claude/hooks/guard-raw-git-ops.sh'
t "the project's own hook is kept"               "$(jq '[.hooks.PreToolUse[].hooks[] | select(.command == "own-guard.sh")] | length' "$S")" 1

[ "$fail" -eq 0 ] && echo "guard-raw-git-ops: all passed" || echo "guard-raw-git-ops: FAILURES"
exit "$fail"
