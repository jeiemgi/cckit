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
