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
