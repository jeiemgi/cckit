#!/bin/sh
# effort-plan-test.sh — self-test for effort-plan.sh, in four parts:
#   1. the ctx weight scale (#277), under bash AND zsh: S=1 M=2 L=4 XL=8; `?` (no ctx: label) weighs
#      2 and is explained by the plan header, any other value weighs 2 and warns on stderr.
#   2. the open-effort read and the "next startable effort per flow" pick that `cckit status`
#      prints (E241.4), under bash AND zsh (kit-status.sh reads them in both); `effort_plan` itself
#      is bash-only and gets one bash smoke case.
#   3. where `cckit effort plan` reads its rows from (#382): the optional local source named by
#      `effort.planSource`, the fallback to GitHub when that source fails or prints nothing, and
#      the `source:` line that says which one the plan was built from.
#   4. `effort_plan` end to end on the weights: an XL effort fills a session, `?` is legend-explained.
# Hermetic: every part stubs gh (the effort list as the JSON `gh issue list --json` returns, each
# effort's blocked_by as the JSON the dependency API returns), so no network is touched.
# Run:  bash scripts/lib/effort-plan-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion

dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

if [ -n "${EP_TEST_INNER:-}" ]; then
  fail=0
  eq()  { if [ "$2" = "$3" ]; then :; else echo "FAIL($EP_TEST_INNER): $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
  has() { case "$2" in *"$3"*) : ;; *) echo "FAIL($EP_TEST_INNER): $1 -> '$2' lacks '$3'"; fail=1 ;; esac; }
  no()  { case "$2" in *"$3"*) echo "FAIL($EP_TEST_INNER): $1 -> '$2' should not contain '$3'"; fail=1 ;; *) : ;; esac; }

  # shellcheck source=/dev/null
  . "$dir/effort-plan.sh"

  # ── 1. the ctx weight scale (no gh, no jq) ──────────────────────────────────────────────────
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

  command -v jq >/dev/null 2>&1 || { echo "  (jq absent — skipping the effort-plan row tests)"; exit "$fail"; }

  # ── 2. the open-effort read and the next-per-flow pick ──────────────────────────────────────
  tmp="$(mktemp -d)"
  stub="$tmp/bin"; mkdir -p "$stub" "$tmp/deps"
  # Stub gh: `issue list` -> $GH_EFFORTS (a JSON array file); `api …/issues/<N>/dependencies/blocked_by`
  # -> $GH_DEPS/<N>.json, or [] when the effort has no fixture. GH_FAIL=1 fails every call.
  cat > "$stub/gh" <<'SH'
#!/bin/sh
[ -z "${GH_FAIL:-}" ] || exit 1
case "$1 $2" in
  "issue list") cat "$GH_EFFORTS" ;;
  "api repos/"*)
    n="${2%/dependencies/blocked_by}"; n="${n##*/}"
    if [ -f "$GH_DEPS/$n.json" ]; then cat "$GH_DEPS/$n.json"; else echo '[]'; fi ;;
  *) echo '[]' ;;
esac
SH
  chmod +x "$stub/gh"
  GH_EFFORTS="$tmp/efforts.json"; GH_DEPS="$tmp/deps"; export GH_EFFORTS GH_DEPS
  PATH="$stub:$PATH"; export PATH

  col() { awk -F'\t' -v f="$1" -v c="$2" '$1==f{print $c}'; }   # col <flow> <column> < next rows

  # ── two flows, one effort blocked by another OPEN effort in its flow ────────────────────────
  # core: 10 (p1) and 11 (p1, blocked_by OPEN 10). docs: 20 (unlabelled priority).
  cat > "$GH_EFFORTS" <<'JSON'
[ {"number":20,"title":"[Effort] 20 · [Docs] cadence page","labels":[{"name":"effort"},{"name":"flow:docs"},{"name":"ctx:S"}]},
  {"number":11,"title":"[Effort] 11 · [Core] second thing","labels":[{"name":"effort"},{"name":"flow:core"},{"name":"ctx:L"},{"name":"priority:p1"}]},
  {"number":10,"title":"[Effort] 10 · [Core] first thing","labels":[{"name":"effort"},{"name":"flow:core"},{"name":"ctx:M"},{"name":"priority:p1"}]} ]
JSON
  echo '[{"number":10,"state":"open"}]' > "$GH_DEPS/11.json"

  open_rows="$(effort_open_rows o/r)"; rc=$?
  eq "open rows: rc 0"                       "$rc" "0"
  eq "open rows: one row per open effort"    "$(printf '%s\n' "$open_rows" | grep -c .)" "3"
  eq "open rows: seven fields, none blank"   "$(printf '%s\n' "$open_rows" | awk -F'\t' 'NF!=7{bad=1} {for(i=1;i<=NF;i++) if($i=="") bad=1} END{print bad+0}')" "0"
  eq "open rows: 11 lists its blocker"       "$(printf '%s\n' "$open_rows" | awk -F'\t' '$1==11{print $5"/"$6}')" "10/10"
  eq "open rows: no blocker reads -"         "$(printf '%s\n' "$open_rows" | awk -F'\t' '$1==10{print $5"/"$6}')" "-/-"
  eq "open rows: missing priority reads -"   "$(printf '%s\n' "$open_rows" | awk -F'\t' '$1==20{print $4}')" "-"

  rows="$(effort_next_rows o/r)"; rc=$?
  eq "next: rc 0"                            "$rc" "0"
  eq "next: exactly one row per flow"        "$(printf '%s\n' "$rows" | grep -c .)" "2"
  eq "next: flows are sorted"                "$(printf '%s\n' "$rows" | cut -f1 | tr '\n' ' ')" "core docs "
  eq "next: core offers the unblocked one"   "$(printf '%s\n' "$rows" | col core 2)" "10"
  eq "next: the blocked effort is never named" "$(printf '%s\n' "$rows" | cut -f2 | grep -c '^11$')" "0"
  eq "next: core counts one waiting"         "$(printf '%s\n' "$rows" | col core 5)" "1"
  eq "next: docs offers its only effort"     "$(printf '%s\n' "$rows" | col docs 2)" "20"
  eq "next: the ctx rides along"             "$(printf '%s\n' "$rows" | col core 3)" "M"
  eq "next: title drops the prefix and tag"  "$(printf '%s\n' "$rows" | col core 4)" "first thing"

  # ── a CLOSED blocker does not block ─────────────────────────────────────────────────────────
  # 10 is gone from the open list (closed); 11 still carries the edge, now pointing at a closed issue.
  cat > "$GH_EFFORTS" <<'JSON'
[ {"number":11,"title":"[Effort] 11 · [Core] second thing","labels":[{"name":"effort"},{"name":"flow:core"},{"name":"ctx:L"}]} ]
JSON
  echo '[{"number":10,"state":"closed"}]' > "$GH_DEPS/11.json"
  rows="$(effort_next_rows o/r)"
  eq "closed blocker: the effort is startable" "$(printf '%s\n' "$rows" | col core 2)" "11"
  eq "closed blocker: nothing is waiting"      "$(printf '%s\n' "$rows" | col core 5)" "0"
  eq "closed blocker: still listed as a blocker" "$(effort_open_rows o/r | cut -f5,6 | tr '\t' '/')" "10/-"

  # ── an OPEN blocker in ANOTHER flow blocks ──────────────────────────────────────────────────
  # core 11 is blocked_by docs 20 (open). core has no other effort, so the flow reports none startable.
  cat > "$GH_EFFORTS" <<'JSON'
[ {"number":20,"title":"[Effort] 20 · [Docs] cadence page","labels":[{"name":"effort"},{"name":"flow:docs"},{"name":"ctx:S"}]},
  {"number":11,"title":"[Effort] 11 · [Core] second thing","labels":[{"name":"effort"},{"name":"flow:core"},{"name":"ctx:L"}]} ]
JSON
  echo '[{"number":20,"state":"open"}]' > "$GH_DEPS/11.json"
  rows="$(effort_next_rows o/r)"
  eq "cross-flow blocker: core keeps its row"    "$(printf '%s\n' "$rows" | grep -c '^core')" "1"
  eq "cross-flow blocker: core names no effort"  "$(printf '%s\n' "$rows" | col core 2)" "-"
  eq "cross-flow blocker: core counts it waiting" "$(printf '%s\n' "$rows" | col core 5)" "1"
  eq "cross-flow blocker: docs is unaffected"    "$(printf '%s\n' "$rows" | col docs 2)" "20"

  # ── an OPEN blocker that is not an effort at all (a plain issue) blocks too ──────────────────
  echo '[{"number":999,"state":"open"}]' > "$GH_DEPS/11.json"
  eq "plain-issue blocker: core names no effort" "$(effort_next_rows o/r | col core 2)" "-"
  rm -f "$GH_DEPS/11.json"

  # ── the pick is pure: priority first (p0 → p3, unlabelled last), then the lowest number ──────
  pick() { printf '%b' "$1" | effort_next_pick | cut -f2; }
  eq "pick: p0 beats p2"               "$(pick '7\tcore\tM\tp2\t-\t-\ta\n9\tcore\tM\tp0\t-\t-\tb\n')" "9"
  eq "pick: a label beats no label"    "$(pick '3\tcore\tM\t-\t-\t-\ta\n9\tcore\tM\tp3\t-\t-\tb\n')" "9"
  eq "pick: a tie takes the lowest number" "$(pick '9\tcore\tM\tp1\t-\t-\ta\n4\tcore\tM\tp1\t-\t-\tb\n')" "4"
  eq "pick: a blocked p0 never outranks a free p3" \
     "$(pick '1\tcore\tM\tp0\t5\t5\ta\n2\tcore\tM\tp3\t-\t-\tb\n')" "2"
  eq "pick: no input, no rows"         "$(printf '' | effort_next_pick | grep -c . )" "0"

  # ── empty and unreadable are different answers ──────────────────────────────────────────────
  echo '[]' > "$GH_EFFORTS"
  rows="$(effort_next_rows o/r)"; rc=$?
  eq "no open effort: rc 0"            "$rc" "0"
  eq "no open effort: no rows"         "$rows" ""
  rows="$(GH_FAIL=1 effort_next_rows o/r)"; rc=$?
  eq "gh fails: rc is non-zero"        "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
  eq "gh fails: no rows"               "$rows" ""
  effort_next_rows "" >/dev/null 2>&1; rc=$?
  eq "no repo: rc is non-zero"         "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"

  # ── effort_plan (bash-only) still prints its session plan from the shared read ───────────────
  if [ "$EP_TEST_INNER" = "bash" ]; then
    cat > "$GH_EFFORTS" <<'JSON'
[ {"number":11,"title":"[Effort] 11 · [Core] second thing","labels":[{"name":"effort"},{"name":"flow:core"},{"name":"ctx:L"}]},
  {"number":10,"title":"[Effort] 10 · [Core] first thing","labels":[{"name":"effort"},{"name":"flow:core"},{"name":"ctx:M"}]} ]
JSON
    echo '[{"number":10,"state":"open"}]' > "$GH_DEPS/11.json"
    plan="$(EFFORT_REPO=o/r effort_plan 2>&1)"; rc=$?
    eq  "plan: rc 0"                         "$rc" "0"
    has "plan: names the flow"               "$plan" "Flow: core"
    has "plan: lists the root effort"        "$plan" "#10   [M ] first thing"
    has "plan: the dependent shows its blocker" "$plan" "second thing   (after #10)   → delegate subs"
    eq  "plan: the blocker is ordered first" \
        "$(printf '%s\n' "$plan" | grep -E '^ +#1[01] ' | awk '{print $1}' | tr '\n' ' ')" "#10 #11 "
    eq  "plan: a blocker and its dependent do not share a session" \
        "$(printf '%s\n' "$plan" | grep -c 'Session ')" "2"
    echo '[]' > "$GH_EFFORTS"
    plan="$(EFFORT_REPO=o/r effort_plan 2>&1)"; rc=$?
    eq  "plan: no efforts is rc 0"           "$rc" "0"
    has "plan: no efforts says so"           "$plan" "no open efforts found"
    plan="$(GH_FAIL=1 EFFORT_REPO=o/r effort_plan 2>&1)"; rc=$?
    eq  "plan: a failed query is rc 1"       "$rc" "1"
    has "plan: a failed query says so"       "$plan" "gh query failed"
  fi

  rm -rf "$tmp"
  if [ "$fail" -eq 0 ]; then echo "PASS($EP_TEST_INNER): effort-plan rows + next-per-flow pick"; fi
  exit "$fail"
fi

fail=0
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || { echo "skip: $sh not installed"; continue; }
  if EP_TEST_INNER="$sh" "$sh" "$0"; then echo "ok: effort-plan weights + rows under $sh"; else fail=1; fi
done

# ── 3. the plan source (#382) ─────────────────────────────────────────────────────────────────
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$ROOT/scripts/lib"
t()    { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
has()  { case "$2" in *"$3"*) echo "ok: $1" ;; *) echo "FAIL: $1 -> output lacks '$3'"; echo "$2" | sed 's/^/    | /'; fail=1 ;; esac; }
lacks() { case "$2" in *"$3"*) echo "FAIL: $1 -> output has '$3'"; fail=1 ;; *) echo "ok: $1" ;; esac; }

tmp="$(mktemp -d)"; tmp2=""; trap 'rm -rf "$tmp" "$tmp2"' EXIT
mkdir -p "$tmp/bin" "$tmp/proj/tools"
GH_LOG="$tmp/gh.log"

# Stub gh: the listing prints the JSON `gh issue list --json number,title,labels` returns; blocked_by
# answers per issue with the JSON the dependency API returns. Every call is logged.
cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >> "$GH_LOG"
case "$1 $2" in
  "issue list") cat <<'JSON'
[ {"number":11,"title":"[Effort] 11 · [Core] gh root","labels":[{"name":"effort"},{"name":"flow:Core"},{"name":"ctx:S"}]},
  {"number":12,"title":"[Effort] 12 · [Core] gh leaf","labels":[{"name":"effort"},{"name":"flow:Core"},{"name":"ctx:M"}]} ]
JSON
    ;;
  "api "*)      case "$2" in */issues/12/dependencies/blocked_by) echo '[{"number":11,"state":"open"}]' ;; *) echo '[]' ;; esac ;;
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
# Count calls (one logged line each).
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

# ── 4. effort_plan end to end on the weights (#277) ───────────────────────────────────────────
# effort_plan end to end against a stub gh: an XL effort fills a session of its own (weight 8, not
# 2), and an effort with no ctx: label shows as `?` with the header saying what `?` weighs.
if command -v jq >/dev/null 2>&1 && command -v bash >/dev/null 2>&1; then
  tmp2="$(mktemp -d)"
  mkdir -p "$tmp2/bin"
  cat > "$tmp2/bin/gh" <<'SH'
#!/bin/sh
case "$1 $2" in
  "issue list") cat <<'JSON'
[ {"number":1,"title":"[Effort] 1 · big one","labels":[{"name":"effort"},{"name":"flow:core"},{"name":"ctx:XL"}]},
  {"number":2,"title":"[Effort] 2 · unsized one","labels":[{"name":"effort"},{"name":"flow:core"}]},
  {"number":3,"title":"[Effort] 3 · small one","labels":[{"name":"effort"},{"name":"flow:core"},{"name":"ctx:S"}]} ]
JSON
    ;;
  *) echo '[]' ;;
esac
SH
  chmod +x "$tmp2/bin/gh"
  out="$(PATH="$tmp2/bin:$PATH" KIT_REPO=o/r EFFORT_REPO=o/r KIT_SESSION_BUDGET=4 \
    bash -c ". '$dir/effort-plan.sh'; effort_plan" 2>&1)"
  chk() { if [ -n "$(printf '%s\n' "$out" | grep -E "$2")" ]; then echo "ok: $1"; else echo "FAIL: $1 (no /$2/ in plan output)"; fail=1; fi; }
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
