#!/usr/bin/env bash
# shellcheck shell=bash
# effort-parity-test.sh — effort #98: the verb (`cckit effort new`) and the skill (/kit-effort-new)
# create structurally IDENTICAL efforts because both call the one shared core `effort_new`. This test
# drives that core with the full skill-shaped inputs and asserts the parity contract:
#   - the four body sections are FILLED (no `<!--` template placeholder left)
#   - the ctx/kind/priority/role/flow label set is applied to the parent
#   - sub-issues carry kind/priority/role labels and are native-linked
#   - every sub title is linted UP FRONT (a bad sub name aborts before anything is created)
# Hermetic: stubs gh (no network/auth). Run:  bash scripts/lib/effort-parity-test.sh
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$ROOT/scripts/lib"
fail=0
t()  { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
tc() { if grep -qE "$2" "$1"; then echo "ok: $3"; else echo "FAIL: $3 (no /$2/ in gh log)"; fail=1; fi; }
tn() { if grep -qE "$2" "$1"; then echo "FAIL: $3 (unexpected /$2/ in gh log)"; fail=1; else echo "ok: $3"; fi; }
command -v jq  >/dev/null 2>&1 || { echo "effort-parity-test: jq required"  >&2; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export GH_LOG="$tmp/gh.log"; export GH_N="$tmp/n"; : > "$GH_LOG"

# Stub gh: log every call as ONE physical line (newlines in the multi-line --body flattened to spaces
# so a single-line grep can see --label, which follows --body), return canned output.
stub="$tmp/bin"; mkdir -p "$stub"
cat > "$stub/gh" <<'SH'
#!/usr/bin/env bash
echo "$*" | tr '\n' ' ' >> "$GH_LOG"; echo >> "$GH_LOG"
case "$1 $2" in
  "issue create")  n=$(( $(cat "$GH_N" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$GH_N"
                   echo "https://github.com/o/r/issues/$n" ;;
  "issue edit")    exit 0 ;;
  "api "*|"api")
    case "$*" in
      *"--method POST"*"/sub_issues"*) exit 0 ;;
      *".id"*) echo "55501" ;;
      *) exit 0 ;;
    esac ;;
  *) exit 0 ;;
esac
SH
chmod +x "$stub/gh"
export PATH="$stub:$PATH"
export KIT_REPO="o/r" EFFORT_REPO="o/r" KIT_BASE_BRANCH="main" KIT_PROJECTS_V2="false"
# shellcheck source=/dev/null
source "$LIB/effort.sh" 2>/dev/null
# shellcheck source=/dev/null
source "$LIB/effort-metrics.sh" 2>/dev/null   # effort_ctx_bucket — so ctx is sized, not the fallback
# shellcheck source=/dev/null
source "$LIB/effort-ops.sh"

# ── Full skill-shaped inputs through the shared core ─────────────────────────────────────────────
: > "$GH_LOG"
parent="$(effort_new \
  --flow Core --role tech-lead --priority p2 \
  --goal "Close the parity gap between the verb and the skill." \
  --scope "1. share core | 2. verb fills body | 3. skill delegates" \
  --for-agents "scripts/lib/effort-ops.sh and skills/kit-effort-new/SKILL.md" \
  --verification "the verb and skill produce identical issues" \
  "demo parity effort" "share core :: factor the logic" "fill the body :: verb wiring")"

t  "core returns the parent number"               "$parent" "1"
t  "core creates parent + 2 subs (3 issues)"      "$(grep -c 'issue create' "$GH_LOG")" "3"
t  "core links 2 native sub-issues"               "$(grep -c 'method POST .*sub_issues' "$GH_LOG")" "2"

# Body is FILLED — every section heading present AND the placeholder comments are gone.
tc "$GH_LOG" 'Close the parity gap between the verb' "body fills ## Goal"
tc "$GH_LOG" '1\. share core \| 2\. verb fills body' "body fills ## Scope"
tc "$GH_LOG" 'scripts/lib/effort-ops\.sh and skills' "body fills ## For agents"
tc "$GH_LOG" 'the verb and skill produce identical'  "body fills ## Verification"
tn "$GH_LOG" '<!--'                                  "no template placeholder left in a filled body"

# Label set on the parent: ctx + kind + priority + role + flow (flow lowercased).
tc "$GH_LOG" 'issue create .*--label ctx:[SMLX]+,kind:task,priority:p2,role:tech-lead,flow:core' \
   "parent carries ctx/kind/priority/role/flow labels"
# Flow tag on the composed title.
tc "$GH_LOG" 'issue edit 1 .*--title \[Effort\] 1 · \[Core\] demo parity effort' \
   "parent title carries the [Core] flow tag + injected number"
# Sub labels: kind/priority/role (no ctx/flow on subs — those are parent-level).
tc "$GH_LOG" 'issue create .*--title \[Effort 1\] 1 · share core.*--label kind:task,priority:p2,role:tech-lead' \
   "sub #1 carries kind/priority/role labels + a proper [Effort N] M title"

# ── A bad sub title aborts the whole op BEFORE anything is created (parity contract) ─────────────
: > "$GH_LOG"; printf '0' > "$GH_N"
effort_new --role tech-lead --goal G --scope S --for-agents A --verification V \
  "clean parent name" "refactor the whole wiring layer thing now" >/dev/null 2>&1 && rc=0 || rc=1
t  "core rejects a bad sub title"                 "$rc" "1"
t  "core creates nothing on a bad sub title"      "$(grep -c 'issue create' "$GH_LOG")" "0"

# ── A bare verb-style call (no body flags) still yields the 4-section scaffold ───────────────────
: > "$GH_LOG"; printf '0' > "$GH_N"
effort_new "minimal effort name" >/dev/null 2>&1
tc "$GH_LOG" '## Goal'         "bare call still emits ## Goal"
tc "$GH_LOG" '## Verification' "bare call still emits ## Verification"
tc "$GH_LOG" '<!--'            "bare call leaves the template placeholders (nothing to fill)"

[ "$fail" -eq 0 ] && echo "ALL OK (effort-parity)" || echo "effort-parity: FAILURES"
exit "$fail"
