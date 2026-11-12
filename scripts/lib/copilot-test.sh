#!/bin/sh
# copilot-test.sh — self-test for copilot.sh under bash AND zsh.
# Network-free: covers the subagent seed composer, and the human brief of copilot_brief run under
# `set -e` against a stubbed plan machine + stub gh/jq (#316). Run:  bash scripts/lib/copilot-test.sh
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

  # --- the human brief under `set -e` (#316) ---------------------------------------------------
  # The dispatcher runs `set -euo pipefail`, so a failing assignment-only command inside
  # copilot_brief kills the verb with no output. Drive the real function in a child shell with
  # errexit on. copilot_brief sources plan-machine.sh + render.sh from its own directory, so the
  # sandbox holds the real copilot.sh + render.sh beside a stub plan machine that emits two rows.
  box="$(mktemp -d "${TMPDIR:-/tmp}/copilot-test.XXXXXX")"
  mkdir -p "$box/bin"
  cp "$dir/copilot.sh" "$dir/render.sh" "$box/"
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
  hasnt "brief without effort"       "$brief" '--effort'
  hasnt "brief heading no effort"    "$brief" 'effort #'

  brief="$(brief_run --effort 5)"; brc=$?
  [ "$brc" -eq 0 ] || { echo "FAIL($CP_TEST_INNER): brief with --effort rc=$brc (want 0)"; fail=1; }
  has   "effort brief heading"       "$brief" '# cckit wave — o/r · effort #5'
  has   "effort brief watch suffix"  "$brief" 'cckit watch --merge --effort 5'
  has   "effort brief wave suffix"   "$brief" 'cckit wave --effort 5'
  rm -rf "$box"

  if [ "$fail" -eq 0 ]; then echo "PASS($CP_TEST_INNER): copilot seed composer + brief under set -e"; fi
  exit "$fail"
fi

rc=0
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || continue
  CP_TEST_INNER="$sh" "$sh" "$0" || rc=1
done
exit "$rc"
