#!/usr/bin/env bash
# shellcheck shell=bash
# effort-ops-test.sh — covers the effort lifecycle ops (#48). Hermetic: stubs gh (no network/auth)
# and uses a throwaway git repo with a bare remote. Run:  bash scripts/lib/effort-ops-test.sh
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$ROOT/scripts/lib"
fail=0
t()  { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
tc() { if grep -qE "$2" "$1"; then echo "ok: $3"; else echo "FAIL: $3 (no /$2/ in gh log)"; fail=1; fi; }
command -v jq  >/dev/null 2>&1 || { echo "effort-ops-test: jq required"  >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "effort-ops-test: git required" >&2; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export GH_LOG="$tmp/gh.log"; export GH_N="$tmp/n"; : > "$GH_LOG"

# Stub gh: log every call, return canned output keyed on the subcommand.
stub="$tmp/bin"; mkdir -p "$stub"
cat > "$stub/gh" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
case "$1 $2" in
  "issue create")  n=$(( $(cat "$GH_N" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$GH_N"
                   echo "https://github.com/o/r/issues/$n" ;;
  "issue edit"|"issue close"|"pr merge") exit 0 ;;
  "issue view")    echo "[Effort] 99 · demo effort" ;;          # --json title -q .title
  "pr create")     echo "https://github.com/o/r/pull/7" ;;
  "api "*|"api")
    case "$*" in
      *"--method POST"*"/sub_issues"*) exit 0 ;;                # link a sub
      *"/sub_issues"*".[].number"*)    printf '101\n102\n' ;;   # list subs (for close)
      *".id"*)                         echo "55501" ;;          # issue db id
      *) exit 0 ;;
    esac ;;
  *) exit 0 ;;
esac
SH
chmod +x "$stub/gh"
export PATH="$stub:$PATH"
export KIT_REPO="o/r" EFFORT_REPO="o/r" KIT_BASE_BRANCH="main"
# shellcheck source=/dev/null
source "$LIB/effort.sh" 2>/dev/null
# shellcheck source=/dev/null
source "$LIB/effort-ops.sh"

# ── effort_new ────────────────────────────────────────────────────────────────────────────────
: > "$GH_LOG"
parent="$(effort_new "[Core] demo effort" "first sub" "second sub" 2>/dev/null)"
t  "effort_new returns the parent number"          "$parent" "1"
t  "effort_new creates parent + 2 subs (3 issues)" "$(grep -c 'issue create' "$GH_LOG")" "3"
t  "effort_new links 2 native sub-issues"          "$(grep -c 'method POST .*sub_issues' "$GH_LOG")" "2"
tc "$GH_LOG" 'issue create .*--title \[Effort\] · \[Core\] demo effort' "effort_new titles the parent"
# a jargon/long name is rejected before any issue is created
: > "$GH_LOG"
effort_new "refactor the whole scripts/kit wiring layer" >/dev/null 2>&1 && rc=0 || rc=1
t  "effort_new rejects a bad title"                "$rc" "1"
t  "effort_new creates nothing on a bad title"     "$(grep -c 'issue create' "$GH_LOG")" "0"

# ── effort_start / effort_pr / effort_close (real git + bare remote) ───────────────────────────
( cd "$tmp" && git init -q --bare remote.git )
( cd "$tmp" && git clone -q remote.git work \
  && cd work && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init \
  && git push -q origin HEAD:main )
cd "$tmp/work"

start_out="$(effort_start 99 demo 2>/dev/null)"
t  "effort_start echoes wt|branch|num" "${start_out##*|}" "99"
t  "effort_start created the branch"   "$(git show-ref --verify --quiet refs/heads/effort/99-demo && echo yes)" "yes"

# move onto the effort branch (its worktree) for pr/close
cd "$tmp/work/.claude/worktrees/effort-99"
: > "$GH_LOG"
effort_pr 99 >/dev/null 2>&1
tc "$GH_LOG" 'pr create .*--base main --head effort/99-demo' "effort_pr opens effort/99 → main"

: > "$GH_LOG"
effort_close 99 >/dev/null 2>&1
tc "$GH_LOG" 'pr merge effort/99-demo .*--squash' "effort_close squash-merges the PR"
tc "$GH_LOG" 'issue close 101'  "effort_close closes sub #101"
tc "$GH_LOG" 'issue close 99 '  "effort_close closes the parent"

[ "$fail" -eq 0 ] && echo "ALL OK (effort-ops)" || echo "effort-ops: FAILURES"
exit "$fail"
