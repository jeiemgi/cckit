#!/usr/bin/env bash
# shellcheck shell=bash
# forge-report-test.sh — E537.1: forge-report.sh counts gh and git lines per file, classes each file,
# says per verb whether it needs a forge (following exec/source transitively), and prints the ratchet
# (files outside the forge layer that call gh). Fixture under its own mktemp -d; no port.
# Run:  bash scripts/forge-report-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
t() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
R="$ROOT/scripts/forge-report.sh"

fx="$(mktemp -d)"; trap 'rm -rf "$fx"' EXIT
mkdir -p "$fx/bin" "$fx/scripts/lib"
cat > "$fx/bin/cckit" <<'CCKIT'
#!/usr/bin/env bash
LIB="$ROOT/scripts/lib"
source "$LIB/common.sh"
cmd="${1:-}"; shift || true
case "$cmd" in
  a)
    # a comment that says gh api is not a call
    source "$LIB/issue.sh"; issue_read "$@" ;;
  b|bee)       exec "$ROOT/scripts/local.sh" "$@" ;;
  c)           echo "nothing here" ;;
  d)           gh pr view "$1" ;;
  e)           source "$LIB/forge.sh"; forge_issue_view "$@" ;;
  f)           source "$LIB/clean.sh"; clean_run "$@" ;;
  help|--help) echo usage ;;
esac
CCKIT
cat > "$fx/scripts/lib/common.sh" <<'SH'
# shared preamble: not attributed to any verb
gh auth status >/dev/null
SH
cat > "$fx/scripts/lib/issue.sh" <<'SH'
. "$(dirname "${BASH_SOURCE[0]}")/transport.sh"
issue_read() { gh issue view "$1" --json title; git -C "$PWD" status; echo "needs gh + jq"; }
SH
cat > "$fx/scripts/lib/transport.sh" <<'SH'
transport() { command -v gh >/dev/null 2>&1 || return 0; }
SH
cat > "$fx/scripts/local.sh" <<'SH'
git fetch origin develop
git -C "$PWD" rev-parse HEAD
SH
cat > "$fx/scripts/lib/forge.sh" <<'SH'
forge_issue_view() { gh api "repos/$1"; }
SH
cat > "$fx/scripts/lib/clean.sh" <<'SH'
clean_run() { git status; forge_available || echo "git only"; }
SH
cat > "$fx/scripts/lib/forge-github.sh" <<'SH'
gh api graphql
SH
cat > "$fx/scripts/lib/noise-test.sh" <<'SH'
gh api never-counted
SH

files="$(bash "$R" --root "$fx" --files)"
row() { printf '%s\n' "$files" | awk -v f="$1" '$1==f {print $2, $3, $4}'; }
t "issue.sh: 1 gh line (the comment-free call), 1 git line, both"  "$(row scripts/lib/issue.sh)"      "1 1 both"
t "transport.sh: the command -v probe counts as gh"                "$(row scripts/lib/transport.sh)"  "1 0 gh-only"
t "local.sh: 2 git lines, git-only"                                "$(row scripts/local.sh)"          "0 2 git-only"
t "bin/cckit: the comment is not a call; verb d calls gh"          "$(row bin/cckit)"                 "1 0 gh-only"
t "common.sh counted as a file"                                    "$(row scripts/lib/common.sh)"     "1 0 gh-only"
t "-test.sh files are not measured"                                "$(row scripts/lib/noise-test.sh)" ""

summary="$(bash "$R" --root "$fx" --summary)"
t "summary: 8 files" "$(printf '%s\n' "$summary" | grep -oE 'files [0-9]+' | sed -n 1p)" "files 8"
t "summary: classes add up"  "$(printf '%s\n' "$summary" | grep -oE 'gh-only [0-9]+ · git-only [0-9]+ · both [0-9]+ · neither [0-9]+')" "gh-only 5 · git-only 2 · both 1 · neither 0"
t "ratchet leaves the forge layer out (forge.sh, forge-github.sh)" "$(bash "$R" --root "$fx" --ratchet)" "4"

verbs="$(bash "$R" --root "$fx" --verbs)"
vrow() { printf '%s\n' "$verbs" | awk -v v="$1" '$1==v {print $2}'; }
t "a needs a forge through issue.sh → transport.sh" "$(vrow a)" "yes"
t "a: via names the files with gh lines"            "$(printf '%s\n' "$verbs" | awk '$1=="a" {print $3, $4}')" "scripts/lib/issue.sh scripts/lib/transport.sh"
t "b: git only"                                     "$(vrow b)"   "no"
t "bee: an alias label is its own row"              "$(vrow bee)" "no"
t "c: nothing"                                      "$(vrow c)"   "no"
t "d: an inline gh call in the dispatcher"          "$(vrow d)"   "yes"
t "e: a call into the forge layer needs a forge"     "$(vrow e)"   "yes"
t "f: a forge_available probe alone is git only"     "$(vrow f)"   "no"
t "help labels are not verbs"                       "$(vrow help)" ""
t "verb summary"  "$(printf '%s\n' "$summary" | grep -oE 'verbs [0-9]+ · needs a forge [0-9]+ · git only [0-9]+')" "verbs 7 · needs a forge 3 · git only 4"

if command -v jq >/dev/null 2>&1; then
  j="$(bash "$R" --root "$fx" --json)"
  t "--json parses" "$(printf '%s' "$j" | jq -r '.summary.files')" "8"
  t "--json verbs carry via" "$(printf '%s' "$j" | jq -r '.verbs[] | select(.verb=="a") | .via | length')" "2"
  t "--json needs_forge is a boolean" "$(printf '%s' "$j" | jq -r '.verbs[] | select(.verb=="d") | .needs_forge')" "true"
fi

# On the real tree the report runs and the ratchet is a number (its value is the effort's business).
t "real tree: ratchet is an integer" "$(bash "$R" --ratchet | grep -cE '^[0-9]+$')" "1"
t "unknown flag exits 2" "$(bash "$R" --nope >/dev/null 2>&1; echo $?)" "2"

[ "$fail" -eq 0 ] && echo "ALL OK (forge-report)"
exit "$fail"
