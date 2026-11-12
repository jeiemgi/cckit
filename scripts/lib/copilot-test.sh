#!/bin/sh
# copilot-test.sh — self-test for copilot.sh pure helper under bash AND zsh.
# Network-free: covers the seed composer, the per-adapter dispatch wording and adapter resolution
# (the gh/plan-driven copilot_brief is exercised by scripts/copilot-loop-test.sh). Run:  bash scripts/lib/copilot-test.sh
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

  if [ "$fail" -eq 0 ]; then echo "PASS($CP_TEST_INNER): copilot seed composer + adapter dispatch"; fi
  exit "$fail"
fi

rc=0
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || continue
  CP_TEST_INNER="$sh" "$sh" "$0" || rc=1
done
exit "$rc"
