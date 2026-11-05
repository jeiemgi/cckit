#!/usr/bin/env bash
# shellcheck shell=bash
# gh-rest-test.sh — the lifecycle verbs work without GraphQL (#396). In rest mode, cckit pr, merge,
# close, new, effort new, effort pr and effort close send only `gh api repos/…` calls — never
# `gh api graphql`, `gh pr …` or `gh issue …` — and every board step is skipped with one notice.
# The default transport is unchanged. Hermetic: a stubbed gh that answers like the REST API (it
# applies --jq with the real jq), a throwaway repo and a bare remote.
# Run: bash scripts/lib/gh-rest-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
set -u
LIB="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$LIB/test-env.sh" && test_env_seal
unset CLAUDE_CODE_REMOTE CCKIT_GH_TRANSPORT
fail=0
t()  { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
tc() { if grep -qE -- "$2" "$1"; then echo "ok: $3"; else echo "FAIL: $3 (no /$2/ in $1)"; fail=1; fi; }
command -v jq  >/dev/null 2>&1 || { echo "gh-rest-test: jq required" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "gh-rest-test: git required" >&2; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export GH_LOG="$tmp/gh.log" GH_N="$tmp/n" GH_CLOSED="" GH_HEAD="fix/9-x" GH_BASE="develop" GH_MERGEABLE="true"
export GH_TITLE="Fix the thing" GH_LABELS='[{"name":"kind:fix"},{"name":"role:tech-lead"}]'
: > "$GH_LOG"

# rest_only <log> <label> — every gh call in <log> is `gh api` on a repos/ endpoint; none is graphql,
# `gh pr …` or `gh issue …`. (The stub logs one call per line: newlines in a body become \036.)
rest_only() {
  local bad
  bad="$(grep -vE '^api (-[^ ]+ [^ ]+ )*repos/' "$1" | head -3)"
  if [ -n "$bad" ]; then echo "FAIL: $2 — non-REST gh calls: $bad"; fail=1; else echo "ok: $2"; fi
  if grep -q graphql "$1"; then echo "FAIL: $2 — a graphql call was made"; fail=1; fi
}

mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'SH'
#!/usr/bin/env bash
# A REST-shaped gh: logs every call; `gh api <endpoint>` answers a fixture, through --jq when given.
{ printf '%s' "$*" | tr '\n' '\036'; echo; } >> "$GH_LOG"
if [ "$1" != api ]; then            # the default (graphql) transport's subcommands
  case "$1 $2" in
    "issue view")   printf '{"state":"OPEN","title":"%s","labels":%s,"milestone":{"title":"M1"},"body":"","projectItems":[]}\n' "$GH_TITLE" "$GH_LABELS" ;;
    "issue create") echo "https://github.com/o/r/issues/50" ;;
    "pr create")    echo "https://github.com/o/r/pull/7" ;;
    "pr view")      printf '{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","baseRefName":"%s","headRefName":"%s"}\n' "$GH_BASE" "$GH_HEAD" ;;
  esac
  exit 0
fi
shift; ep="$1"; shift
method=""; jqx=""; fields=""; accept=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X|--method) method="$2"; shift 2 ;;
    --jq|-q)     jqx="$2"; shift 2 ;;
    -f|-F|--raw-field|--field) fields=1; shift 2 ;;
    -H|--header) accept="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$method" ] || { [ -n "$fields" ] && method=POST || method=GET; }
next() { n=$(( $(cat "$GH_N" 2>/dev/null || echo 49) + 1 )); echo "$n" > "$GH_N"; echo "$n"; }
state_of() { case " $GH_CLOSED " in *" $1 "*) echo closed ;; *) echo open ;; esac; }
json='{}'
case "$method $ep" in
  "GET repos/o/r/milestones") json='[{"number":2,"title":"M0"},{"number":3,"title":"M1"}]' ;;
  "POST repos/o/r/issues")    n="$(next)"; json="{\"number\":$n,\"html_url\":\"https://github.com/o/r/issues/$n\",\"user\":{\"login\":\"me\"}}" ;;
  "GET repos/o/r/issues")     json='[{"number":99,"title":"[Effort] 99 · demo effort"},{"number":5,"title":"PR","pull_request":{}}]' ;;
  "GET repos/o/r/issues/"*/sub_issues) json='[{"number":101,"state":"closed"},{"number":102,"state":"closed"}]' ;;
  "GET repos/o/r/issues/"*/timeline)
    sub="${ep#repos/o/r/issues/}"; sub="${sub%/timeline}"
    json="[{\"event\":\"cross-referenced\",\"source\":{\"issue\":{\"number\":6$sub,\"body\":\"mentions #$sub\",\"repository_url\":\"https://api.github.com/repos/o/r\",\"pull_request\":{\"merged_at\":\"2026-01-01\"}}}},
           {\"event\":\"cross-referenced\",\"source\":{\"issue\":{\"number\":5$sub,\"body\":\"Closes #$sub\",\"repository_url\":\"https://api.github.com/repos/o/r\",\"pull_request\":{\"merged_at\":\"2026-01-01\"}}}}]" ;;
  "GET repos/o/r/issues/"*)
    n="${ep##*/}"
    json="{\"number\":$n,\"title\":\"$GH_TITLE\",\"state\":\"$(state_of "$n")\",\"body\":\"## Goal\\nship it\",\"labels\":$GH_LABELS,\"milestone\":{\"number\":3,\"title\":\"M1\"},\"user\":{\"login\":\"me\"}}" ;;
  "POST repos/o/r/pulls")     json='{"number":7,"html_url":"https://github.com/o/r/pull/7","user":{"login":"me"}}' ;;
  "GET repos/o/r/pulls")      json="[{\"number\":9,\"head\":{\"ref\":\"$GH_HEAD\"},\"state\":\"open\",\"merged_at\":null}]" ;;
  "GET repos/o/r/pulls/"*)
    n="${ep##*/}"
    case "$accept" in *diff*) printf 'diff --git a/src/app.ts b/src/app.ts\n+app\n'; exit 0 ;; esac
    json="{\"number\":$n,\"title\":\"feat: sub $n\",\"mergeable\":$GH_MERGEABLE,\"mergeable_state\":\"clean\",\"base\":{\"ref\":\"$GH_BASE\"},\"head\":{\"ref\":\"$GH_HEAD\"},\"body\":\"Closes #42\\nFixes #43\\nsee #44\",\"state\":\"open\",\"merged_at\":null,\"merge_commit_sha\":\"abc1234def\"}" ;;
  "PUT repos/o/r/pulls/"*/merge) json='{"merged":true}' ;;
esac
if [ -n "$jqx" ]; then printf '%s' "$json" | jq -r -c "$jqx"; else printf '%s\n' "$json"; fi
SH
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH" KIT_REPO="o/r" EFFORT_REPO="o/r" KIT_BASE_BRANCH="develop" KIT_WT_INSTALL=0
unset KIT_CONFIG

# shellcheck source=/dev/null
. "$LIB/gh-rest.sh"

# ── the chooser ───────────────────────────────────────────────────────────────────────────────────
t "default transport is graphql"                    "$(cckit_gh_transport)" "graphql"
t "a cloud session defaults to rest"                "$(CLAUDE_CODE_REMOTE=true cckit_gh_transport)" "rest"
t "CCKIT_GH_TRANSPORT=graphql wins in the cloud"    "$(CLAUDE_CODE_REMOTE=true CCKIT_GH_TRANSPORT=graphql cckit_gh_transport)" "graphql"
t "CCKIT_GH_TRANSPORT=rest forces rest locally"     "$(CCKIT_GH_TRANSPORT=rest cckit_gh_transport)" "rest"
t "an unknown value falls to the default"           "$(CCKIT_GH_TRANSPORT=soap cckit_gh_transport 2>/dev/null)" "graphql"
tc <(CCKIT_GH_TRANSPORT=soap cckit_gh_transport 2>&1 >/dev/null) "must be rest or graphql" "an unknown value warns"

# ── pure helpers ──────────────────────────────────────────────────────────────────────────────────
t "closing refs are read from a PR body" \
  "$(printf 'Closes #42\nfixes #43 and resolves #7\nsee #44\nCloses #42\n' | gh_rest_closing_refs | tr '\n' ' ')" "7 42 43 "

# ── board steps in rest mode ──────────────────────────────────────────────────────────────────────
: > "$GH_LOG"
out="$(CCKIT_GH_TRANSPORT=rest bash -c '
  . "$1/gh-project.sh"
  load_project_ids; echo "rc=$?"
  project_add_item NODE; echo "rc=$?"
  project_set_single_select I F O; echo "rc=$?"
  project_set_text I F T; echo "rc=$?"
  project_find_item_by_issue 5; echo "rc=$?"
  project_issue_status 5; echo "rc=$?"' _ "$LIB" 2>"$tmp/board.err")"
t "every board function returns 0 in rest mode"     "$(printf '%s' "$out" | grep -c '^rc=0$')" "6"
t "the board functions print nothing on stdout"     "$(printf '%s' "$out" | grep -vc '^rc=')" "0"
t "the notice is printed once"                      "$(grep -c 'board step skipped' "$tmp/board.err")" "1"
tc "$tmp/board.err" "^cckit: board step skipped \(GraphQL unavailable; the project's built-in workflows move the card\)$" "the notice wording"
t "no gh call is made for the board"                "$(wc -l < "$GH_LOG" | tr -d ' ')" "0"

[ "$fail" -eq 0 ] && echo "gh-rest: all passed" || echo "gh-rest: FAILURES"
exit "$fail"
