#!/bin/sh
# effort-plan-test.sh — self-test for effort-plan.sh: the open-effort read and the "next startable
# effort per flow" pick that `cckit status` prints (E241.4).
# Hermetic: a stubbed gh serves the effort list and each effort's blocked_by from fixture files, so
# no network is touched. The row readers run under bash AND zsh (kit-status.sh reads them in both);
# `effort_plan` itself is bash-only and gets one bash smoke case.
# Run:  bash scripts/lib/effort-plan-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion

dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

if [ -n "${EP_TEST_INNER:-}" ]; then
  fail=0
  eq()  { if [ "$2" = "$3" ]; then :; else echo "FAIL($EP_TEST_INNER): $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
  has() { case "$2" in *"$3"*) : ;; *) echo "FAIL($EP_TEST_INNER): $1 -> '$2' lacks '$3'"; fail=1 ;; esac; }
  no()  { case "$2" in *"$3"*) echo "FAIL($EP_TEST_INNER): $1 -> '$2' should not contain '$3'"; fail=1 ;; *) : ;; esac; }
  command -v jq >/dev/null 2>&1 || { echo "  (jq absent — skipping effort-plan-test)"; exit 0; }

  # shellcheck source=/dev/null
  . "$dir/effort-plan.sh"

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

rc=0
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || continue
  EP_TEST_INNER="$sh" "$sh" "$0" || rc=1
done
exit "$rc"
