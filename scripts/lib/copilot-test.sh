#!/bin/sh
# copilot-test.sh — self-test for copilot.sh under bash AND zsh.
# Network-free: covers the seed composer, the per-adapter dispatch wording, adapter resolution, and
# the human brief of copilot_brief run under `set -e` against a stubbed plan machine + stub gh/jq
# (#316). Run:  bash scripts/lib/copilot-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion

dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

if [ -n "${CP_TEST_INNER:-}" ]; then
  . "$dir/copilot.sh"
  fail=0
  has() { case "$2" in *"$3"*) ;; *) echo "FAIL($CP_TEST_INNER): $1 missing '[$3]'"; fail=1 ;; esac; }

  seed="$(_copilot_seed 42 'wire the thing')"
  has "seed has issue view"   "$seed" 'gh issue view 42'
  has "seed has title"        "$seed" 'implement "wire the thing"'
  has "seed has pr verb"      "$seed" 'cckit pr 42'
  has "seed has close verb"   "$seed" 'cckit close 42'
  has "seed has check gate"   "$seed" 'bash scripts/check.sh'
  has "seed forbids asking"   "$seed" 'never ask'
  # The seed is wave data: it names no runtime, so the same prompt serves a Claude or a Codex worker.
  no()  { case "$2" in *"$3"*) echo "FAIL($CP_TEST_INNER): $1 has unexpected '[$3]'"; fail=1 ;; esac; }
  no  "seed names no Claude tool" "$seed" 'Task subagent'
  no  "seed names no runtime"     "$seed" 'Codex'

  # Dispatch wording is the adapter's.
  cl="$(_copilot_dispatch claude 2 '101 103')"; cx="$(_copilot_dispatch codex 2 '101 103')"
  has "claude dispatch: Task subagents"   "$cl" 'spawn 2 parallel Task subagent(s)'
  has "claude dispatch: Task isolation"   "$cl" 'Task isolation: "worktree"'
  no  "claude dispatch: no orchestrate launch" "$cl" 'cckit orchestrate --agent codex'
  has "codex dispatch: cckit owns the worktrees" "$cx" 'cckit creates the worktrees'
  has "codex dispatch: launch line names the wave" "$cx" 'cckit orchestrate --agent codex --detach 101 103'
  has "codex dispatch: results are collected" "$cx" 'cckit orchestrate --results'
  no  "codex dispatch: no Task tool wording" "$cx" 'Task isolation'

  # Which adapters the brief speaks for: flag, then env, then the project (claude when unset).
  eq() { if [ "$2" = "$3" ]; then :; else echo "FAIL($CP_TEST_INNER): $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
  eq "adapter flag wins"        "$(CCKIT_ADAPTER=claude _copilot_adapters codex)" "codex"
  eq "both is canonical order"  "$(_copilot_adapters both)" "claude codex"
  eq "env when no flag"         "$(CCKIT_ADAPTER=codex _copilot_adapters '')" "codex"
  _copilot_adapters cursor >/dev/null 2>&1; eq "an unknown adapter is refused" "$?" "1"
  cfgd="$(mktemp -d)"
  printf '{"adapters":["codex"]}\n' > "$cfgd/cckit.config.json"
  eq "project selection when neither" "$(cd "$cfgd" && unset CCKIT_ADAPTER && KIT_CONFIG="$cfgd/cckit.config.json" _copilot_adapters '')" "codex"
  rm -rf "$cfgd"

  # --- the human brief under `set -e` (#316) ---------------------------------------------------
  # The dispatcher runs `set -euo pipefail`, so a failing assignment-only command inside
  # copilot_brief kills the verb with no output. Drive the real function in a child shell with
  # errexit on. copilot_brief sources plan-machine.sh + render.sh from its own directory, so the
  # sandbox holds the real copilot.sh + render.sh + the two adapter-resolution libs beside a stub
  # plan machine that emits two rows.
  box="$(mktemp -d "${TMPDIR:-/tmp}/copilot-test.XXXXXX")"
  mkdir -p "$box/bin"
  cp "$dir/copilot.sh" "$dir/render.sh" "$dir/adapter-select.sh" "$dir/config-path.sh" "$box/"
  cat > "$box/plan-machine.sh" <<'STUB'
plan_machine() {
  printf '0\t-\t7\tS\t-\t[Effort 5] 1 · first thing\n'
  printf '1\t-\t8\tM\t-\tsecond thing\n'
}
STUB
  for tool in gh jq; do
    printf '#!/bin/sh\nexit 0\n' > "$box/bin/$tool"; chmod +x "$box/bin/$tool"
  done
  brief_run() {  # brief_run [copilot_brief args…] — prints the brief, returns the child's rc
    ( cd "$box" && PATH="$box/bin:$PATH" CCKIT_NO_GLOW=1 CCKIT_OUTPUT=human COPILOT_REPO=o/r \
        "$CP_TEST_INNER" -c 'set -e; . ./copilot.sh; copilot_brief "$@"' copilot "$@" )
  }
  hasnt() { case "$2" in *"$3"*) echo "FAIL($CP_TEST_INNER): $1 has '[$3]'"; fail=1 ;; esac; }

  brief="$(brief_run)"; brc=$?
  [ "$brc" -eq 0 ] || { echo "FAIL($CP_TEST_INNER): brief without --effort rc=$brc (want 0)"; fail=1; }
  has   "brief has heading"          "$brief" '# cckit wave — o/r'
  has   "brief lists wave-0 issue"   "$brief" '### #7 · [S] · first thing'
  has   "brief has watch line"       "$brief" 'cckit watch --merge'
  has   "brief carries the default adapter dispatch" "$brief" '### Claude Code — spawn 1 parallel Task subagent(s)'
  hasnt "brief without effort"       "$brief" '--effort'
  hasnt "brief heading no effort"    "$brief" 'effort #'

  brief="$(brief_run --effort 5)"; brc=$?
  [ "$brc" -eq 0 ] || { echo "FAIL($CP_TEST_INNER): brief with --effort rc=$brc (want 0)"; fail=1; }
  has   "effort brief heading"       "$brief" '# cckit wave — o/r · effort #5'
  has   "effort brief watch suffix"  "$brief" 'cckit watch --merge --effort 5'
  has   "effort brief wave suffix"   "$brief" 'cckit wave --effort 5'
  rm -rf "$box"

  if [ "$fail" -eq 0 ]; then echo "PASS($CP_TEST_INNER): copilot seed composer + adapter dispatch + brief under set -e"; fi
  exit "$fail"
fi

rc=0
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || continue
  CP_TEST_INNER="$sh" "$sh" "$0" || rc=1
done
exit "$rc"
