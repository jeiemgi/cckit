#!/usr/bin/env bash
# shellcheck shell=bash
# effort-plan-test.sh — covers where `cckit effort plan` reads its rows from (#382): the optional
# local source named by `effort.planSource`, the fallback to GitHub when that source fails or
# prints nothing, and the `source:` line that says which one the plan was built from.
# Hermetic: a stub `gh` on PATH that logs every call, throwaway source scripts, no network.
# Run:  bash scripts/lib/effort-plan-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$ROOT/scripts/lib"
fail=0
t()    { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
has()  { case "$2" in *"$3"*) echo "ok: $1" ;; *) echo "FAIL: $1 -> output lacks '$3'"; echo "$2" | sed 's/^/    | /'; fail=1 ;; esac; }
lacks() { case "$2" in *"$3"*) echo "FAIL: $1 -> output has '$3'"; fail=1 ;; *) echo "ok: $1" ;; esac; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/proj/tools"
GH_LOG="$tmp/gh.log"

# Stub gh: the listing prints the TSV the real `--jq` would produce; blocked_by answers per issue.
cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >> "$GH_LOG"
case "$1 $2" in
  "issue list") printf '11\tCore\tS\t[Effort] 11 · [Core] gh root\n12\tCore\tM\t[Effort] 12 · [Core] gh leaf\n' ;;
  "api "*)      case "$2" in */issues/12/dependencies/blocked_by) echo "11" ;; *) echo "" ;; esac ;;
esac
STUB
chmod +x "$tmp/bin/gh"

mk() { printf '%s\n' "$2" > "$tmp/proj/tools/$1"; chmod +x "$tmp/proj/tools/$1"; }
mk good.sh '#!/usr/bin/env bash
echo "# age: 2h"
printf "21\tDocs\tL\t[Effort] 21 · [Docs] stub root\n"
printf "22\tDocs\tS\t[Effort] 22 · [Docs] stub leaf\t21\n"'
mk noage.sh '#!/usr/bin/env bash
printf "31\tDocs\tS\tstub only\n"'
mk fail.sh '#!/usr/bin/env bash
printf "41\tDocs\tS\tshould not appear\n"
exit 3'
mk empty.sh '#!/usr/bin/env bash
exit 0'
mk args.sh '#!/usr/bin/env bash
printf "51\tDocs\tS\trepo=%s cwd=%s\n" "$1" "$(basename "$PWD")"'
mk blank.sh '#!/usr/bin/env bash
printf "61\t\t\tempty flow and ctx\t\n"'
printf '{"github":{"repo":"o/r"},"effort":{"planSource":"tools/good.sh"}}' > "$tmp/proj/cckit.config.json"

# plan [VAR=value …] — run effort_plan in a clean shell; stdout+stderr captured together.
plan() {
  : > "$GH_LOG"
  ( cd "$tmp/proj" && env -u KIT_CONFIG -u EFFORT_PLAN_SOURCE -u KIT_EFFORT_PLAN_SOURCE \
      PATH="$tmp/bin:$PATH" GH_LOG="$GH_LOG" EFFORT_REPO="o/r" "$@" \
      bash -c "source '$LIB/config-path.sh'; source '$LIB/effort-plan.sh'; effort_plan" 2>&1 )
}
# Count calls, not lines: the listing's multi-line --jq program spans several log lines.
gh_calls() { grep -c '^gh ' "$GH_LOG" | tr -d ' '; }

# ── 1. a working local source: its rows, its blockers, no gh, source + age named ───────────────
out="$(plan KIT_EFFORT_PLAN_SOURCE=tools/good.sh)"
has   "stub rows are planned"            "$out" "#21 "
has   "stub second row is planned"       "$out" "stub leaf"
has   "stub blockers are honored"        "$out" "(after #21)"
lacks "GitHub rows are absent"           "$out" "gh root"
t     "gh is never called"               "$(gh_calls)" "0"
has   "output names the stub as source"  "$out" "source: planSource tools/good.sh"
has   "output carries the reported age"  "$out" "age 2h"
# the blocker forces a second session even though L(4)+S(1) alone would already overflow budget 4;
# prove ordering instead: the blocker is listed before its dependent.
t     "blocker is ordered before its dependent" \
  "$(printf '%s\n' "$out" | grep -oE '#2[12] ' | tr -d '\n')" "#21 #22 "

out="$(plan KIT_EFFORT_PLAN_SOURCE=tools/noage.sh)"
has   "a source with no age is still named" "$out" "source: planSource tools/noage.sh"
lacks "no age is invented"                  "$out" "age "

out="$(plan EFFORT_PLAN_SOURCE=tools/noage.sh KIT_EFFORT_PLAN_SOURCE=tools/good.sh)"
has   "EFFORT_PLAN_SOURCE wins over the config value" "$out" "source: planSource tools/noage.sh"

out="$(plan KIT_EFFORT_PLAN_SOURCE="$tmp/proj/tools/args.sh")"
has   "source receives the repo as \$1"          "$out" "repo=o/r"
has   "relative source runs from the project root" "$out" "cwd=proj"

out="$(plan KIT_EFFORT_PLAN_SOURCE=tools/blank.sh)"
has   "empty flow and ctx columns keep the title in place" "$out" "empty flow and ctx"
has   "empty ctx renders as unknown"                       "$out" "[? ]"

# ── 2. a source that fails, prints nothing, or is not executable falls back to GitHub ──────────
out="$(plan KIT_EFFORT_PLAN_SOURCE=tools/fail.sh)"
has   "failing source: GitHub rows planned"   "$out" "gh root"
has   "failing source: GitHub blockers kept"  "$out" "(after #11)"
lacks "failing source: its rows are dropped"  "$out" "should not appear"
has   "failing source: GitHub named"          "$out" "source: GitHub (o/r)"
has   "failing source: the fallback is said"  "$out" "planSource tools/fail.sh failed (exit 3)"

out="$(plan KIT_EFFORT_PLAN_SOURCE=tools/empty.sh)"
has   "empty source: GitHub rows planned"     "$out" "gh root"
has   "empty source: GitHub named"            "$out" "source: GitHub (o/r)"
has   "empty source: the fallback is said"    "$out" "planSource tools/empty.sh printed no rows"

out="$(plan KIT_EFFORT_PLAN_SOURCE=tools/missing.sh)"
has   "missing source: GitHub rows planned"   "$out" "gh root"
has   "missing source: the fallback is said"  "$out" "planSource tools/missing.sh is not executable"

# ── 3. planSource unset: the GitHub plan, with the source named and no fallback note ───────────
out="$(plan)"
has   "unset: GitHub rows planned"            "$out" "gh leaf"
has   "unset: GitHub named"                   "$out" "source: GitHub (o/r)"
lacks "unset: no fallback note"               "$out" "planSource"
t     "unset: one listing + one blocked_by call per effort" "$(gh_calls)" "3"

# ── 4. load_kit_config exports the key; the exported value drives the plan end to end ──────────
if command -v jq >/dev/null 2>&1; then
  out="$( : > "$GH_LOG"; cd "$tmp/proj" && env -u KIT_CONFIG -u EFFORT_PLAN_SOURCE -u KIT_EFFORT_PLAN_SOURCE -u EFFORT_REPO \
      PATH="$tmp/bin:$PATH" GH_LOG="$GH_LOG" \
      bash -c "source '$LIB/kit-config.sh'; load_kit_config >/dev/null 2>&1; source '$LIB/effort-plan.sh'; effort_plan" 2>&1 )"
  has "config key effort.planSource reaches the plan" "$out" "source: planSource tools/good.sh"
  t   "config-driven local plan calls no gh"          "$(gh_calls)" "0"
fi

[ "$fail" -eq 0 ] && echo "ALL OK (effort-plan)" || echo "effort-plan: FAILURES"
exit "$fail"
#!/bin/sh
# effort-plan-test.sh — the ctx weight scale behind `cckit effort plan`, under bash AND zsh.
#
# S=1 M=2 L=4 XL=8. A value outside the scale used to weigh 2 with nothing said, so an effort with a
# missing or misspelled ctx: label was planned as an M. It still weighs 2 (the plan must go on), but
# the fallback now names itself: `?` (no ctx: label) is legend-explained in the plan header, and any
# other unknown value warns on stderr.
# Network-free for the weight helper; the effort_plan run stubs gh. Run:  bash scripts/lib/effort-plan-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion

dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

if [ -n "${EP_TEST_INNER:-}" ]; then
  . "$dir/effort-plan.sh"
  fail=0
  eq() { if [ "$2" != "$3" ]; then echo "FAIL($EP_TEST_INNER): $1 -> '[$2]', want '[$3]'"; fail=1; fi; }
  has() { case "$2" in *"$3"*) : ;; *) echo "FAIL($EP_TEST_INNER): $1 -> '[$2]' lacks '[$3]'"; fail=1 ;; esac; }

  eq "weight S"  "$(_ep_weight S)"  "1"
  eq "weight M"  "$(_ep_weight M)"  "2"
  eq "weight L"  "$(_ep_weight L)"  "4"
  eq "weight XL" "$(_ep_weight XL)" "8"
  for c in S M L XL; do eq "weight $c is quiet" "$(_ep_weight "$c" 2>&1 >/dev/null)" ""; done

  # no label at all: weighs the default, silently here — the plan header carries the legend.
  eq "weight ? (unlabeled)"       "$(_ep_weight '?' 2>/dev/null)" "2"
  eq "weight ? is quiet"          "$(_ep_weight '?' 2>&1 >/dev/null)" ""
  # a value outside the scale: still the default weight, and stderr names the value + the issue.
  eq "weight XXL falls back to 2" "$(_ep_weight XXL 2>/dev/null)" "2"
  has "weight XXL warns"          "$(_ep_weight XXL 41 2>&1 >/dev/null)" "ctx:XXL"
  has "the warning names the issue" "$(_ep_weight XXL 41 2>&1 >/dev/null)" "#41"
  has "the warning names the weight used" "$(_ep_weight XXL 41 2>&1 >/dev/null)" "weighed 2"
  has "lowercase xl is not XL"    "$(_ep_weight xl 7 2>&1 >/dev/null)" "ctx:xl"
  exit "$fail"
fi

fail=0
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || { echo "skip: $sh not installed"; continue; }
  if EP_TEST_INNER="$sh" "$sh" "$0"; then echo "ok: effort-plan weights under $sh"; else fail=1; fi
done

# effort_plan end to end against a stub gh: an XL effort fills a session of its own (weight 8, not
# 2), and an effort with no ctx: label shows as `?` with the header saying what `?` weighs.
if command -v jq >/dev/null 2>&1 && command -v bash >/dev/null 2>&1; then
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  mkdir -p "$tmp/bin"
  cat > "$tmp/bin/gh" <<'SH'
#!/bin/sh
case "$1 $2" in
  "issue list") printf '1\tcore\tXL\t[Effort] 1 · big one\n2\tcore\t?\t[Effort] 2 · unsized one\n3\tcore\tS\t[Effort] 3 · small one\n' ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$tmp/bin/gh"
  out="$(PATH="$tmp/bin:$PATH" KIT_REPO=o/r EFFORT_REPO=o/r KIT_SESSION_BUDGET=4 \
    bash -c ". '$dir/effort-plan.sh'; effort_plan" 2>&1)"
  chk() { if printf '%s\n' "$out" | grep -qE "$2"; then echo "ok: $1"; else echo "FAIL: $1 (no /$2/ in plan output)"; fail=1; fi; }
  chk "the header explains the unlabeled weight" '\? = no ctx: label, weighed 2'
  chk "an unlabeled effort renders as ?"         '#2 +\[\? \] unsized one'
  chk "an XL effort is flagged to delegate"      '#1 +\[XL\] big one.*delegate subs'
  # XL (8) overflows the budget of 4 on its own, so the ? effort (2) opens Session 2 — were XL
  # weighed 2, XL + ? would share Session 1 and the S effort would open Session 2.
  t_sess="$(printf '%s\n' "$out" | awk '/Session/{s=$2} /#2 /{print s}' | tr -d ':')"
  if [ "$t_sess" = "2" ]; then echo "ok: XL weighs a whole session (next effort opens Session 2)"
  else echo "FAIL: effort after an XL landed in Session '[$t_sess]', want '[2]'"; fail=1; fi
  s3="$(printf '%s\n' "$out" | awk '/Session/{s=$2} /#3 /{print s}' | tr -d ':')"
  if [ "$s3" = "2" ]; then echo "ok: ? (2) + S (1) share Session 2"
  else echo "FAIL: S effort landed in Session '[$s3]', want '[2]'"; fail=1; fi
else
  echo "skip: jq/bash missing — effort_plan run not exercised"
fi

[ "$fail" -eq 0 ] && echo "ALL OK (effort-plan)" || echo "effort-plan: FAILURES"
exit "$fail"
