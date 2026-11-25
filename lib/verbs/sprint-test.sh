#!/usr/bin/env bash
# shellcheck shell=bash
# sprint-test.sh — `cckit effort sprint` (lib/verbs/sprint.sh, #570): the week arithmetic, and the
# milestone open / list / close over the forge shim (test-forge-shim.sh). Hermetic, no network.
# errors: strict — a test runner: rc 1 on any failed assertion
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/lib/core/test-env.sh" && test_env_seal
LIB="$ROOT/lib"
fail=0
t()  { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
tc() { if grep -qE "$2" "$1"; then echo "ok: $3"; else echo "FAIL: $3 (no /$2/ in $1)"; fail=1; fi; }
tn() { if grep -qE "$2" "$1"; then echo "FAIL: $3 (found /$2/)"; fail=1; else echo "ok: $3"; fi; }
command -v jq >/dev/null 2>&1 || { echo "sprint-test: jq required" >&2; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export GH_LOG="$tmp/gh.log"; : > "$GH_LOG"
stub="$tmp/bin"
# shellcheck source=/dev/null
. "$LIB/forge/test-forge-shim.sh"; forge_shim_install "$stub"
export PATH="$stub:$PATH" GH_TOKEN=test-token CCKIT_FORGE=github KIT_REPO=o/r
# The milestones and the sprint's issues, per test (MS_JSON / MS_ISSUES).
export GH_FIXTURE="$tmp/fixture.sh"
cat > "$GH_FIXTURE" <<'SH'
case "$method $ep" in
  "GET repos/o/r/milestones") out="${MS_JSON:-[]}" ;;
  "POST repos/o/r/milestones") out='{"number":12}' ;;
  "PATCH repos/o/r/milestones/"*) out='{}' ;;
  "GET repos/o/r/issues") case "$path" in *milestone=*) out="${MS_ISSUES:-[]}" ;; esac ;;
esac
SH
# shellcheck source=/dev/null
. "$LIB/verbs/sprint.sh"

# ── the week: ISO week name, Monday to Monday ─────────────────────────────────────────────────
t "a Tuesday names its ISO week"        "$(sprint_name 2026-11-24)" "2026-W48"
t "a Sunday is still that week"         "$(sprint_name 2026-11-29)" "2026-W48"
t "the next Monday starts the next one" "$(sprint_name 2026-11-30)" "2026-W49"
t "Jan 1st 2027 (a Friday) is 2026-W53" "$(sprint_name 2027-01-01)" "2026-W53"
t "bounds: Monday to the next Monday"   "$(sprint_bounds 2026-11-24)" "$(printf '2026-11-23\t2026-11-30')"
t "bounds of a Monday start on it"      "$(sprint_bounds 2026-11-30)" "$(printf '2026-11-30\t2026-12-07')"
t "bounds across a month"               "$(sprint_bounds 2026-12-31)" "$(printf '2026-12-28\t2027-01-04')"
sprint_name 2026-13-45 >/dev/null 2>&1; t "a bad day is a usage error" "$?" "2"
sprint_name "next week" >/dev/null 2>&1; t "prose is a usage error" "$?" "2"
t "no date means today" "$(sprint_name)" "$(date '+%G-W%V')"

# ── open: create, keep, update the goal ───────────────────────────────────────────────────────
: > "$GH_LOG"
out="$(MS_JSON='[{"number":3,"title":"v1"}]' sprint_open --goal "ship the advisor" --date 2026-11-25 2>/dev/null)"
t  "open prints the sprint name" "$out" "2026-W48"
tc "$GH_LOG" '^POST repos/o/r/milestones \{"title":"2026-W48","description":"Sprint goal: ship the advisor\\n\\nMonday 2026-11-23 to Monday 2026-11-30\.","due_on":"2026-11-30T00:00:00Z"\}' \
   "open creates the milestone: title, goal, due the closing Monday"
: > "$GH_LOG"
MS_JSON='[{"number":12,"title":"2026-W48","state":"open"}]' sprint_open --date 2026-11-25 >/dev/null 2>&1
tn "$GH_LOG" '^(POST|PATCH) ' "open keeps an existing sprint and writes nothing"
: > "$GH_LOG"
MS_JSON='[{"number":12,"title":"2026-W48","state":"open"}]' sprint_open --goal "new goal" --date 2026-11-25 >/dev/null 2>&1
tc "$GH_LOG" '^PATCH repos/o/r/milestones/12 \{"description":"Sprint goal: new goal' "open --goal updates the goal of an existing sprint"
sprint_open --bogus >/dev/null 2>&1; t "open: an unknown flag is a usage error" "$?" "2"

# ── list: only sprint milestones ──────────────────────────────────────────────────────────────
out="$(MS_JSON='[{"title":"v1","state":"open","open_issues":1,"closed_issues":0},{"title":"2026-W48","state":"open","open_issues":2,"closed_issues":5,"due_on":"2026-11-30T00:00:00Z"}]' sprint_list)"
t "list: a header and the sprint rows only" "$out" "$(printf 'sprint\tstate\topen\tclosed\tdue\n2026-W48\topen\t2\t5\t2026-11-30')"
out="$(MS_JSON='[]' sprint_list)"
case "$out" in *"no open sprint"*"effort sprint open"*) echo "ok: list with none says how to open one" ;; *) echo "FAIL: empty list: $out"; fail=1 ;; esac

# ── close: the review + retrospective page, then the milestone ─────────────────────────────────
export MS_JSON='[{"number":12,"title":"2026-W48","state":"open","description":"Sprint goal: ship the advisor\n\nMonday 2026-11-23 to Monday 2026-11-30."}]'
export MS_ISSUES='[{"number":579,"title":"Advisor skill","state":"closed"},{"number":580,"title":"Grill stage","state":"closed"},{"number":586,"title":"Release","state":"open"},{"number":9,"title":"a PR","state":"closed","pull_request":{}}]'
: > "$GH_LOG"
page="$(sprint_close 2026-W48 --dry-run 2>/dev/null)"
case "$page" in *"## Sprint goal"*"ship the advisor"*"### Done (2)"*"#579 Advisor skill"*"### Carried over (1)"*"#586 Release"*"## Retrospective"*) echo "ok: close --dry-run prints goal, done, carried over and the retro" ;; *) echo "FAIL: dry-run page: $page"; fail=1 ;; esac
case "$page" in *"a PR"*) echo "FAIL: a pull request was listed as sprint work"; fail=1 ;; *) echo "ok: pull requests are not sprint items" ;; esac
tn "$GH_LOG" '^PATCH ' "close --dry-run closes nothing"
: > "$GH_LOG"
printf 'Shown: the advisor routing five stages.\n' > "$tmp/review.md"
path="$(sprint_close 2026-W48 --review-file "$tmp/review.md" --retro "Keep one commit per sub." --out "$tmp/out/sprint.md" 2>/dev/null)"; rc=$?
t  "close succeeds" "$rc" "0"
t  "close prints the page path" "$path" "$tmp/out/sprint.md"
tc "$tmp/out/sprint.md" '^Shown: the advisor routing five stages\.$' "close puts the review text on the page"
tc "$tmp/out/sprint.md" '^Keep one commit per sub\.$' "close puts the retrospective text on the page"
tc "$GH_LOG" '^PATCH repos/o/r/milestones/12 \{"state":"closed","description":"Sprint goal: ship the advisor.*## Review\\n2 done, 1 carried over\. Review and retrospective: sprint\.md"\}' \
   "close closes the milestone and appends the one-line review"
sprint_close 2026-W99x >/dev/null 2>&1; t "close: a bad sprint name is a usage error" "$?" "2"
MS_JSON='[]' sprint_close 2026-W40 >/dev/null 2>&1; t "close: no such sprint is rc 1" "$?" "1"

# ── without a forge: the week still works, the milestone verbs refuse ─────────────────────────
t "name runs with no forge" "$(CCKIT_FORGE=none GH_TOKEN='' sprint_name 2026-11-24)" "2026-W48"
CCKIT_FORGE=none GH_TOKEN='' sprint_open >/dev/null 2>&1; t "open refuses with no forge" "$?" "1"

# ── the dispatcher ────────────────────────────────────────────────────────────────────────────
t "cckit effort sprint name" "$(bash "$ROOT/bin/cckit" effort sprint name 2026-11-24 2>/dev/null)" "2026-W48"
bash "$ROOT/bin/cckit" effort sprint bogus >/dev/null 2>&1; t "an unknown sprint sub-verb is rc 2" "$?" "2"

exit "$fail"
