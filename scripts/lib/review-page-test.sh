#!/usr/bin/env bash
# review-page-test.sh — a page opens only where a reader can see it, the fallback never fails, and
# an answer is written to the issue or to a file (#451).
#
# Hermetic: `lavish-axi`, `npx`, `gh` and `uname` are stubs on a sealed PATH that log their
# arguments; no browser starts and no network is touched. Every file lands under one mktemp dir.
# Each case names the whole session environment it runs in, because the host's own (CI on the
# runner, CLAUDECODE in an agent's shell) would otherwise decide the outcome.
#
# Run:  bash scripts/lib/review-page-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
# shellcheck shell=bash
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIBF="$ROOT/scripts/lib/review-page.sh"
command -v jq >/dev/null 2>&1 || { echo "review-page-test: jq absent — skipping"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "review-page-test: git absent — skipping"; exit 0; }
# shellcheck source=/dev/null
. "$ROOT/scripts/lib/test-env.sh" && test_env_seal

TMP="$(cd "$(mktemp -d)" && pwd -P)" || exit 1
trap 'rm -rf "$TMP"' EXIT

fail=0
t()   { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
yes() { case "$2" in *"$3"*) echo "ok: $1" ;; *) echo "FAIL: $1 -> missing '$3' in [$2]"; fail=1 ;; esac; }
no()  { case "$2" in *"$3"*) echo "FAIL: $1 -> found '$3' in [$2]"; fail=1 ;; *) echo "ok: $1" ;; esac; }

# ── a sealed PATH: the tools the lib needs, and nothing that could be a real page tool ─────────
SEALED="$TMP/sealed"; mkdir -p "$SEALED"
for tool in sh bash jq git grep sed awk sort cat mkdir rm dirname basename chmod ls pwd env tr head tail find mktemp cut cp mv date cksum; do
  src="$(command -v "$tool" 2>/dev/null)" || continue
  case "$src" in /*) ln -s "$src" "$SEALED/$tool" ;; esac
done
STUB="$TMP/stub"; mkdir -p "$STUB"       # lavish-axi + gh + uname
NPXONLY="$TMP/npxonly"; mkdir -p "$NPXONLY"
LOG="$TMP/calls.log"; : > "$LOG"
printf '0\n' > "$TMP/lavish-rc"
printf 'Darwin\n' > "$TMP/os"
: > "$TMP/gh-comments"
printf '0\n' > "$TMP/gh-rc"

cat > "$STUB/lavish-axi" <<EOF
#!/bin/sh
echo "lavish-axi \$*" >> "$LOG"
echo "stub page output"
exit "\$(cat "$TMP/lavish-rc")"
EOF
cat > "$NPXONLY/npx" <<EOF
#!/bin/sh
echo "npx \$*" >> "$LOG"
exit 0
EOF
cat > "$STUB/uname" <<EOF
#!/bin/sh
cat "$TMP/os"
EOF
cat > "$NPXONLY/uname" <<EOF
#!/bin/sh
cat "$TMP/os"
EOF
# gh: `issue view` answers the comment bodies recorded so far; `issue comment` records the body
# file and prints a URL, or fails with the code in gh-rc.
cat > "$STUB/gh" <<EOF
#!/bin/sh
echo "gh \$*" >> "$LOG"
case "\$1 \$2" in
  "issue view") cat "$TMP/gh-comments" ;;
  "issue comment")
    rc="\$(cat "$TMP/gh-rc")"
    [ "\$rc" = 0 ] || { echo "stub gh: refused" >&2; exit "\$rc"; }
    bf=""; prev=""
    for a in "\$@"; do [ "\$prev" = "--body-file" ] && bf="\$a"; prev="\$a"; done
    cat "\$bf" >> "$TMP/gh-comments"; cp "\$bf" "$TMP/gh-last-body"
    echo "https://example.invalid/o/r/issues/\$3#issuecomment-1" ;;
esac
exit 0
EOF
chmod +x "$STUB"/* "$NPXONLY"/*

# ── projects ───────────────────────────────────────────────────────────────────────────────────
project() {  # <name> <config-json> -> a git repo with that config; echoes its dir
  mkdir -p "$TMP/$1/.claude" "$TMP/$1/.lavish"
  git -C "$TMP/$1" init -q 2>/dev/null
  printf '%s\n' "$2" > "$TMP/$1/.claude/kit.config.json"
  printf '<!DOCTYPE html><title>p</title>\n' > "$TMP/$1/.lavish/plan.html"
  printf '# The plan\n\nstep one\n' > "$TMP/$1/.lavish/plan.md"
  printf '%s\n' "$TMP/$1"
}
GH="$(project gh '{"github":{"repo":"o/r"}}')"
NOGH="$(project nogh '{"project":{"name":"x"}}')"
OFF="$(project off '{"github":{"repo":"o/r"},"reviewPages":{"enabled":false}}')"

# page <project> [VAR=value …] -- <args…>
# Runs the verb in an ATTENDED Claude Code session on a machine with a display and the page tool on
# PATH; the VAR=value pairs change that one fact at a time. stdin/stdout/stderr are never a TTY.
# stdout is the result; stderr lands in $TMP/err; the exit code is the verb's.
page() {
  local proj="$1"; shift
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  ( cd "$proj" && env -i HOME="$TMP/home" PATH="$STUB:$SEALED" KIT_CONFIG="$proj/.claude/kit.config.json" \
      CLAUDECODE=1 CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_CODE_SESSION_ATTENDED=1 DISPLAY=:0 \
      ${envs[@]+"${envs[@]}"} bash "$LIBF" "$@" </dev/null 2> "$TMP/err" )
}
calls() { tr '\n' '|' < "$LOG"; }
reset() { : > "$LOG"; : > "$TMP/gh-comments"; rm -f "$TMP/gh-last-body"; printf '0\n' > "$TMP/gh-rc"; printf '0\n' > "$TMP/lavish-rc"; printf 'Darwin\n' > "$TMP/os"; }

# ── 1. mode: the attended session gets a page ──────────────────────────────────────────────────
t "attended session, tool on PATH -> page" "$(page "$GH" -- mode)" "page"
t "on by default: a config with no reviewPages key -> page" "$(page "$NOGH" -- mode)" "page"
t "--llm mode is one JSON object" "$(page "$GH" CCKIT_OUTPUT=json -- mode)" '{"mode":"page"}'

# ── 2. mode: every no-browser session falls back, and says why ─────────────────────────────────
yes "CI -> terminal"                    "$(page "$GH" CI=true -- mode)" "terminal: CI is set"
t   "CI=false is not CI"                "$(page "$GH" CI=false -- mode)" "page"
yes "unattended run -> terminal"        "$(page "$GH" CCKIT_HEADLESS=1 -- mode)" "terminal: CCKIT_HEADLESS is set"
yes "claude -p (sdk-cli) -> terminal"   "$(page "$GH" CLAUDE_CODE_ENTRYPOINT=sdk-cli -- mode)" "terminal: a headless Claude Code session (CLAUDE_CODE_ENTRYPOINT=sdk-cli)"
yes "unattended Claude session -> terminal" "$(page "$GH" CLAUDE_CODE_SESSION_ATTENDED=0 -- mode)" "terminal: a headless Claude Code session (CLAUDE_CODE_SESSION_ATTENDED=0)"
yes "SSH -> terminal"                   "$(page "$GH" SSH_CONNECTION=1.2.3.4 -- mode)" "terminal: an SSH session"
printf 'Linux\n' > "$TMP/os"
yes "Linux with no display -> terminal" "$(page "$GH" DISPLAY= -- mode)" "terminal: no display"
t   "Linux with WAYLAND_DISPLAY -> page" "$(page "$GH" DISPLAY= WAYLAND_DISPLAY=wayland-0 -- mode)" "page"
printf 'Darwin\n' > "$TMP/os"
t   "macOS needs no DISPLAY"            "$(page "$GH" DISPLAY= -- mode)" "page"
yes "no agent session and no TTY -> terminal" "$(page "$GH" CLAUDECODE= -- mode)" "terminal: no terminal and no attended agent session"
yes "the off switch -> terminal"        "$(page "$OFF" -- mode)" "terminal: review pages are off (reviewPages.enabled is false in $OFF/.claude/kit.config.json)"
yes "CCKIT_PAGES=terminal -> terminal"  "$(page "$GH" CCKIT_PAGES=terminal -- mode)" "terminal: CCKIT_PAGES=terminal"
t   "CCKIT_PAGES=page overrides the session checks" "$(page "$GH" CCKIT_PAGES=page CI=true CLAUDECODE= -- mode)" "page"
yes "CCKIT_PAGES=page does not override the off switch" "$(page "$OFF" CCKIT_PAGES=page -- mode)" "terminal: review pages are off"
yes "no lavish-axi and no npx -> terminal" "$(page "$GH" PATH="$SEALED" -- mode)" "terminal: neither lavish-axi nor npx is on PATH"
t   "--llm terminal mode carries the reason" "$(page "$GH" CI=1 CCKIT_OUTPUT=json -- mode | jq -r '.mode + "|" + .reason')" "terminal|CI is set: a CI job has no reader"
for e in CI=true CCKIT_HEADLESS=1 CLAUDE_CODE_ENTRYPOINT=sdk-cli SSH_TTY=/dev/pts/1 CCKIT_PAGES=terminal; do
  page "$GH" "$e" -- mode >/dev/null; t "mode exits 0 under $e" "$?" "0"
done

# ── 3. open: page mode runs the tool with the file ─────────────────────────────────────────────
reset
out="$(page "$GH" -- open .lavish/plan.html --fallback .lavish/plan.md)"; rc=$?
t "open rc" "$rc" "0"
t "open ran the tool with the html file, once" "$(calls)" "lavish-axi .lavish/plan.html|"
yes "open passes the tool's output through" "$out" "stub page output"
no  "open in page mode does not print the fallback" "$out" "step one"
t "open keeps .lavish/ out of git status" "$(git -C "$GH" status --porcelain --untracked-files=all | grep -c '\.lavish' )" "0"
t "…through the local exclude file, written once" "$(grep -c '^\.lavish/$' "$GH/.git/info/exclude")" "1"
page "$GH" -- open .lavish/plan.html >/dev/null
t "…and a second open adds no second line" "$(grep -c '^\.lavish/$' "$GH/.git/info/exclude")" "1"
reset
out="$(page "$GH" PATH="$NPXONLY:$SEALED" -- open .lavish/plan.html)"
t "without the binary, open goes through npx -y" "$(calls)" "npx -y lavish-axi .lavish/plan.html|"
reset
page "$GH" -- open .lavish/plan.html --fallback .lavish/plan.md -- --reopen >/dev/null
t "flags after -- reach the tool" "$(calls)" "lavish-axi .lavish/plan.html --reopen|"
reset
out="$(page "$GH" CCKIT_OUTPUT=json -- open .lavish/plan.html)"
t "--llm open: stdout is one JSON object" "$out" '{"mode":"page","file":".lavish/plan.html"}'

# ── 4. open: the fallback prints the markdown, runs no tool and exits 0 ────────────────────────
reset
out="$(page "$GH" CI=true -- open .lavish/plan.html --fallback .lavish/plan.md)"; rc=$?
t "fallback rc" "$rc" "0"
t "fallback runs no tool" "$(calls)" ""
yes "fallback prints the markdown" "$out" "step one"
yes "fallback says why, on stderr" "$(cat "$TMP/err")" "page: terminal output — CI is set"
out="$(page "$GH" CCKIT_HEADLESS=1 -- open .lavish/plan.html)"; rc=$?
t "fallback with no markdown rc" "$rc" "0"
yes "fallback with no markdown tells the agent to print" "$out" "terminal: no page was opened (CCKIT_HEADLESS is set"
out="$(page "$OFF" -- open .lavish/plan.html --fallback .lavish/plan.md)"; rc=$?
t "integration off: open rc" "$rc" "0"
yes "integration off: the markdown is printed" "$out" "step one"
t "integration off: no tool ran" "$(calls)" ""
out="$(page "$GH" CI=true CCKIT_OUTPUT=json -- open .lavish/plan.html --fallback .lavish/plan.md)"
t "--llm fallback names mode, reason and fallback file" "$(printf '%s' "$out" | jq -r '.mode + "|" + .fallback')" "terminal|.lavish/plan.md"

# ── 5. open: a tool that fails falls back instead of failing ───────────────────────────────────
reset; printf '7\n' > "$TMP/lavish-rc"
out="$(page "$GH" -- open .lavish/plan.html --fallback .lavish/plan.md)"; rc=$?
t "tool exits 7 -> open still exits 0" "$rc" "0"
yes "tool exits 7 -> the markdown is printed" "$out" "step one"
yes "tool exits 7 -> stderr names the exit code" "$(cat "$TMP/err")" "lavish-axi exited 7"

# ── 6. open: usage errors are the only non-zero exits ──────────────────────────────────────────
reset
page "$GH" -- open >/dev/null; t "open with no file -> rc 2" "$?" "2"
page "$GH" -- open .lavish/absent.html >/dev/null; t "open with a missing file -> rc 2" "$?" "2"
page "$GH" -- open .lavish/plan.html --fallback .lavish/absent.md >/dev/null; t "open with a missing fallback -> rc 2" "$?" "2"
t "a usage error runs no tool" "$(calls)" ""
page "$GH" -- frobnicate >/dev/null; t "unknown subcommand -> rc 2" "$?" "2"

# ── 7. poll / reply / end: handed to the tool in page mode, a no-op in terminal mode ───────────
reset
page "$GH" -- poll .lavish/plan.html --agent-reply "done" >/dev/null; t "poll rc" "$?" "0"
page "$GH" -- end .lavish/plan.html >/dev/null
t "poll and end reach the tool with their arguments" "$(calls)" "lavish-axi poll .lavish/plan.html --agent-reply done|lavish-axi end .lavish/plan.html|"
printf '3\n' > "$TMP/lavish-rc"
page "$GH" -- poll .lavish/plan.html >/dev/null; t "poll returns the tool's own exit code" "$?" "3"
reset
page "$GH" CI=true -- poll .lavish/plan.html >/dev/null; t "poll in terminal mode -> rc 0" "$?" "0"
t "poll in terminal mode runs no tool" "$(calls)" ""

# ── 8. answer: a GitHub project with an issue gets ONE comment ─────────────────────────────────
reset
printf 'Chose option B: one PR.\n' > "$TMP/answer.md"
out="$(page "$GH" -- answer --kind decision --title "Ship as one PR" --issue 42 --body-file "$TMP/answer.md")"; rc=$?
t "answer rc" "$rc" "0"
yes "answer commented on the issue, in the configured repo" "$(calls)" "gh issue comment 42 --repo o/r --body-file "
yes "answer prints where it went" "$out" "issue #42 https://example.invalid/o/r/issues/42#issuecomment-1"
body="$(cat "$TMP/gh-last-body")"
yes "comment: kind and title in the heading" "$body" "### Decision answer: Ship as one PR"
yes "comment: the answer text" "$body" "Chose option B: one PR."
yes "comment: the marker that makes a re-run a no-op" "$body" "<!-- cckit:page-answer kind=decision id="
t "answer wrote no file in a GitHub project" "$([ -e "$GH/docs/answers" ] && echo made || echo none)" "none"
: > "$LOG"
out="$(page "$GH" -- answer --kind decision --title "Ship as one PR" --issue 42 --body-file "$TMP/answer.md")"; rc=$?
t "same answer again: rc 0" "$rc" "0"
no  "same answer again: no second comment" "$(calls)" "issue comment"
yes "same answer again: says so" "$out" "issue #42 (already recorded)"
: > "$LOG"
# page() feeds /dev/null on stdin, so an answer with no --body-file has an empty body.
page "$GH" -- answer --kind decision --title "Ship as one PR" --issue '#42' >/dev/null
t "an empty body is refused" "$?" "2"
no "an empty body posts nothing" "$(calls)" "issue comment"
printf 'Chose option A instead.\n' > "$TMP/answer2.md"
page "$GH" -- answer --kind decision --title "Ship as one PR" --issue '#42' --body-file "$TMP/answer2.md" >/dev/null
yes "a different answer on the same issue is a new comment" "$(calls)" "gh issue comment 42"
out="$(page "$GH" CCKIT_OUTPUT=json -- answer --kind grill --title "Round 1" --issue 42 --body-file "$TMP/answer.md")"
t "--llm answer is one JSON object" "$(printf '%s' "$out" | jq -c '[.ok, .where, .issue, .written]')" '[true,"issue",42,true]'
reset; printf '1\n' > "$TMP/gh-rc"
page "$GH" -- answer --kind plan --title "Plan" --issue 42 --body-file "$TMP/answer.md" >/dev/null; rc=$?
t "a refused comment -> rc 1" "$rc" "1"
yes "a refused comment names the cause" "$(cat "$TMP/err")" "could not comment on #42"
reset
page "$GH" CI=true -- answer --kind plan --title "Approved in the terminal" --issue 7 --body-file "$TMP/answer.md" >/dev/null
yes "terminal mode writes the answer back too" "$(calls)" "gh issue comment 7 --repo o/r"

# ── 9. answer: no GitHub (or no issue) writes a versioned file ─────────────────────────────────
reset
today="$(date +%Y-%m-%d)"
out="$(page "$NOGH" -- answer --kind decision --title "Launch: week 12, not 14!" --body-file "$TMP/answer.md")"; rc=$?
want="$NOGH/docs/answers/$today-decision-launch-week-12-not-14.md"
t "file answer rc" "$rc" "0"
t "file answer prints the path" "$out" "file $want"
t "file answer made no gh call" "$(calls)" ""
f="$(cat "$want" 2>/dev/null)"
yes "file: heading" "$f" "# Decision answer: Launch: week 12, not 14!"
yes "file: date" "$f" "- Recorded: $today"
yes "file: the answer text" "$f" "Chose option B: one PR."
t "file is untracked-but-visible to git, so it can be committed" "$(git -C "$NOGH" status --porcelain --untracked-files=all | grep -c 'docs/answers/')" "1"
yes "file answer tells the agent to commit it" "$(cat "$TMP/err")" "commit it with the change"
out="$(page "$NOGH" -- answer --kind decision --title "Launch: week 12, not 14!" --body-file "$TMP/answer.md")"
yes "same file answer again: nothing written" "$out" "(already recorded)"
t "same file answer again: still one file" "$(find "$NOGH/docs/answers" -type f | wc -l | tr -d ' ')" "1"
page "$NOGH" -- answer --kind decision --title "Launch: week 12, not 14!" --body-file "$TMP/answer2.md" >/dev/null
t "a different answer under the same title gets its own file" "$([ -f "${want%.md}-2.md" ] && echo yes || echo no)" "yes"
# The file name starts with the date: the same answer on a later day is still one record.
mv "$want" "$NOGH/docs/answers/2020-01-01-decision-launch-week-12-not-14.md"
out="$(page "$NOGH" -- answer --kind decision --title "Launch: week 12, not 14!" --body-file "$TMP/answer.md")"
yes "same file answer on a later day: nothing written" "$out" "docs/answers/2020-01-01-decision-launch-week-12-not-14.md (already recorded)"
t "…and no file dated today appears" "$([ -e "$want" ] && echo made || echo none)" "none"
out="$(page "$NOGH" -- answer --kind plan --title "Q3 plan" --issue 9 --body-file "$TMP/answer.md")"
yes "no GitHub repo in the config: an --issue still goes to a file" "$out" "file $NOGH/docs/answers/$today-plan-q3-plan.md"
yes "…and the file records the issue" "$(cat "$NOGH/docs/answers/$today-plan-q3-plan.md")" "- Issue: #9"
out="$(page "$GH" -- answer --kind plan --title "Before the issue exists" --body-file "$TMP/answer.md")"
yes "a GitHub project with no --issue writes a file" "$out" "file $GH/docs/answers/$today-plan-before-the-issue-exists.md"
t "…and makes no gh call" "$(calls)" ""

# ── 10. answer: reviewPages.answers / answersDir decide when they are set ──────────────────────
FORCEF="$(project forcef '{"github":{"repo":"o/r"},"reviewPages":{"answers":"file","answersDir":"knowledge/decisions"}}')"
reset
out="$(page "$FORCEF" -- answer --kind decision --title "Pick" --issue 5 --body-file "$TMP/answer.md")"
yes "answers=file wins over a GitHub issue, in answersDir" "$out" "file $FORCEF/knowledge/decisions/$today-decision-pick.md"
t "answers=file makes no gh call" "$(calls)" ""
FORCEI="$(project forcei '{"reviewPages":{"answers":"issue"}}')"
page "$FORCEI" -- answer --kind decision --title "Pick" --body-file "$TMP/answer.md" >/dev/null
t "answers=issue with no --issue -> rc 2" "$?" "2"
ESC="$(project esc '{"reviewPages":{"answersDir":"../outside"}}')"
page "$ESC" -- answer --kind decision --title "Pick" --body-file "$TMP/answer.md" >/dev/null
t "an answersDir that leaves the repo -> rc 2" "$?" "2"
t "…and nothing is written outside" "$([ -e "$TMP/outside" ] && echo made || echo none)" "none"

# ── 11. answer: usage errors ───────────────────────────────────────────────────────────────────
page "$GH" -- answer --kind verdict --title x --body-file "$TMP/answer.md" >/dev/null; t "unknown kind -> rc 2" "$?" "2"
page "$GH" -- answer --kind plan --body-file "$TMP/answer.md" >/dev/null; t "no title -> rc 2" "$?" "2"
page "$GH" -- answer --kind plan --title x --issue abc --body-file "$TMP/answer.md" >/dev/null; t "non-numeric issue -> rc 2" "$?" "2"
page "$GH" -- answer --kind plan --title x --body-file "$TMP/absent.md" >/dev/null; t "missing body file -> rc 2" "$?" "2"
page "$GH" -- answer --title x --kind >/dev/null; t "a flag with no value -> rc 2" "$?" "2"
ABS="$(project abs "{\"reviewPages\":{\"answersDir\":\"$TMP/abs-out\"}}")"
page "$ABS" -- answer --kind decision --title "Pick" --body-file "$TMP/answer.md" >/dev/null
t "an absolute answersDir -> rc 2" "$?" "2"
t "…and nothing is written there" "$([ -e "$TMP/abs-out" ] && echo made || echo none)" "none"
reset
page "$GH" -- reply .lavish/plan.html --agent-reply "noted" >/dev/null
t "reply reaches the tool with its arguments" "$(calls)" "lavish-axi reply .lavish/plan.html --agent-reply noted|"

# ── 12. the same answers under zsh (scripts/lib is sourced by both shells) ─────────────────────
if command -v zsh >/dev/null 2>&1; then
  ZSH="$(command -v zsh)"
  zmode() { ( cd "$GH" && env -i HOME="$TMP/home" PATH="$STUB:$SEALED" KIT_CONFIG="$GH/.claude/kit.config.json" \
      CLAUDECODE=1 CLAUDE_CODE_ENTRYPOINT=cli DISPLAY=:0 "$@" "$ZSH" -c ". '$LIBF'; rp_mode" </dev/null 2>/dev/null ); }
  t "zsh: attended -> page" "$(zmode)" "page"
  yes "zsh: CI -> terminal" "$(zmode CI=true)" "terminal	CI is set"
  reset
  ( cd "$GH" && env -i HOME="$TMP/home" PATH="$STUB:$SEALED" KIT_CONFIG="$GH/.claude/kit.config.json" \
      CLAUDECODE=1 CLAUDE_CODE_ENTRYPOINT=cli DISPLAY=:0 "$ZSH" -c ". '$LIBF'; rp_open .lavish/plan.html; rp_answer --kind plan --title 'Z plan' --issue 3 --body-file '$TMP/answer.md'" </dev/null >/dev/null 2>&1 )
  yes "zsh: open runs the tool" "$(calls)" "lavish-axi .lavish/plan.html|"
  yes "zsh: answer comments on the issue" "$(calls)" "gh issue comment 3 --repo o/r"
  zerr="$( cd "$NOGH" && env -i HOME="$TMP/home" PATH="$STUB:$SEALED" KIT_CONFIG="$NOGH/.claude/kit.config.json" \
      "$ZSH" -c ". '$LIBF'; rp_answer --kind grill --title 'Z round' --body-file '$TMP/answer.md'; rp_answer --title x --kind" </dev/null 2>&1 >/dev/null )"
  t "zsh: a file answer is written" "$([ -f "$NOGH/docs/answers/$today-grill-z-round.md" ] && echo yes || echo no)" "yes"
  no "zsh: a flag with no value prints no shell error" "$zerr" "shift count"
else
  echo "ok: zsh absent — the zsh cases are skipped"
fi

if [ "$fail" -eq 0 ]; then echo "PASS review-page-test"; else echo "FAIL review-page-test"; fi
exit "$fail"
