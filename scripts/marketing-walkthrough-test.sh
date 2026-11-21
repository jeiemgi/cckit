#!/usr/bin/env bash
# shellcheck shell=bash
# marketing-walkthrough-test.sh — the Marketing docs' sequence, run through bin/cckit (#487).
#
#   cckit init --profile marketing --yes  ->  cckit task new  ->  cckit task start
#     ->  cckit task finish --all  ->  cckit status
#
# in a project that already has a commit and an `origin`. A reader who followed the docs pages hit
# eight defects on this path; each assertion below is one of them:
#   1. the base branch written to the config is one the repository has, and a run with no
#      confirmation says what it left undone (through bin/cckit, which used to hand init cckit's
#      own config and with it cckit's own base branch);
#   2. the cckit files are committed on the base branch and pushed, so the task's folder has them;
#   3. `cckit status` shows the light task, in the report and in --llm;
#   6. the next steps of a light-task project name no label or milestone script;
#   7. `.cckit/` and `.claude/worktrees/` are gitignored;
#   8. no shipped command, skill or template holds an absolute home-directory path.
# (4 and 5 — the instruction file and the plain-language rule — are in init-content-test.sh.)
#
# Hermetic: HOME is a temp dir, `gh` is a stub that logs every call, "GitHub" is a bare repository
# in the temp dir. No network, no real repository.
# Run:  bash scripts/marketing-walkthrough-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/scripts/lib/test-env.sh" && test_env_seal
CCKIT="$ROOT/bin/cckit"
fail=0
t()     { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
has()   { if grep -qF -- "$3" <<<"$2"; then echo "ok: $1"; else echo "FAIL: $1 -> '$3' not in output:"; printf '%s\n' "$2" | tail -20; fail=1; fi; }
hasnt() { if grep -qF -- "$3" <<<"$2"; then echo "FAIL: $1 -> '$3' found in output"; fail=1; else echo "ok: $1"; fi; }

for dep in jq git perl; do
  command -v "$dep" >/dev/null 2>&1 || { echo "marketing-walkthrough-test: $dep absent — skipping (dependency-light gate)"; exit 0; }
done

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
tmp="$(cd "$tmp" && pwd -P)"
export HOME="$tmp/home"; mkdir -p "$HOME"
printf '[user]\n\tname = Test Person\n\temail = test@example.com\n' > "$HOME/.gitconfig"
export GH_LOG="$tmp/gh.log"; : > "$GH_LOG"

mkdir -p "$tmp/stubs"
cat > "$tmp/stubs/gh" <<'STUB'
#!/usr/bin/env bash
# Logs every call. Reads answer "nothing there yet"; writes succeed.
printf '%s\n' "$*" >> "$GH_LOG"
case "${1:-} ${2:-}" in
  "auth status") exit 0 ;;
  "config get") echo https; exit 0 ;;
  "api user") echo tester; exit 0 ;;
  "repo view") exit 1 ;;
  "label list") exit 0 ;;
  "label create") exit 0 ;;
  "pr list") exit 0 ;;
  "pr create") echo "https://github.com/tester/site/pull/1"; exit 0 ;;
  "issue list") echo '[]'; exit 0 ;;
  "api graphql") exit 1 ;;
esac
if [ "${1:-}" = "api" ]; then
  case " $* " in
    *"/protection "*) case " $* " in *" -X PUT "*) cat >/dev/null; echo '{}'; exit 0 ;; esac
                      echo "gh: Branch not protected (HTTP 404)" >&2; exit 1 ;;
    *"/milestones"*)  exit 0 ;;
    *" -X PATCH "*)   exit 0 ;;
    *)                echo false; exit 0 ;;
  esac
fi
exit 1
STUB
chmod +x "$tmp/stubs/gh"
export PATH="$tmp/stubs:$PATH"
export KIT_INIT_PREFLIGHT=0 KIT_INIT_TTY=0 KIT_ASCII=1 NO_COLOR=1 KIT_WT_INSTALL=0
unset KIT_CONFIG KIT_BASE_BRANCH 2>/dev/null || true

# new_project <dir> — a project with one commit on `main` and an empty bare `origin`.
new_project() {
  mkdir -p "$1"; git init -q --bare "$1.git"
  git -C "$1" init -q; git -C "$1" symbolic-ref HEAD refs/heads/main
  echo "# Site" > "$1/README.md"; git -C "$1" add -A; git -C "$1" commit -q -m first
  git -C "$1" remote add origin "$1.git"
}

# ── a run with no terminal and no --yes ─────────────────────────────────────────────────────────
q="$tmp/quiet"; new_project "$q"
out="$(cd "$q" && "$CCKIT" init --profile marketing --owner-login tester --repo tester/quiet 2>&1 < /dev/null)"
t "no --yes: rc 0" "$?" "0"
t "no --yes: the base branch is the repository's, not cckit's own" "$(jq -r .github.baseBranch "$q/.claude/kit.config.json")" "main"
has "no --yes: says the setup did not run" "$out" "Git and GitHub setup: not run"
has "no --yes: says the cckit files are not committed, with the command" "$out" "To commit them on 'main' and push:  cckit init --yes"
hasnt "no --yes: no label or milestone script in the next steps" "$out" "setup-labels.sh"
t "no --yes: .cckit/ is gitignored" "$(grep -cxF '.cckit/' "$q/.gitignore")" "1"
t "no --yes: .claude/worktrees/ is gitignored" "$(grep -cxF '.claude/worktrees/' "$q/.gitignore")" "1"
t "no --yes: the labels come from this project's config" \
  "$(cd "$q" && KIT_LABELS_LIST=1 bash "$ROOT/scripts/setup-labels.sh" 2>/dev/null | grep -c '^kind:post	')" "1"
# The second run a reader makes: the same command with --yes commits the files that are there.
out="$(cd "$q" && "$CCKIT" init --yes 2>&1 < /dev/null)"; t "then --yes: rc 0" "$?" "0"
has "then --yes: the cckit files are committed" "$out" "[done   ] cckit files commit"
t "then --yes: the working tree is clean" "$(git -C "$q" status --porcelain)" ""
t "then --yes: origin has them" "$(git -C "$q.git" ls-tree -r --name-only main -- CLAUDE.md .claude/kit.config.json | tr '\n' ' ')" ".claude/kit.config.json CLAUDE.md "

# ── the walkthrough ─────────────────────────────────────────────────────────────────────────────
p="$tmp/site"; new_project "$p"; cd "$p" || exit 1
out="$("$CCKIT" init --profile marketing --yes --owner-login tester --repo tester/site 2>&1 < /dev/null)"
t "init --yes: rc 0" "$?" "0"
has "init: the plan lists the cckit files commit before anything runs" "$out" "Save the cckit files as one commit on 'main'"
has "init: the commit is made" "$out" "[done   ] cckit files commit"
has "init: nothing failed" "$out" "0 failed"
t "init: the working tree is clean" "$(git status --porcelain)" ""
t "init: the commit is on origin's base branch" "$(git -C "$p.git" log -1 --format=%s main)" "chore: add the cckit project files"
t "init: no ignored file was committed" "$(git ls-files .claude/settings.local.json .claude/kit.manifest.json .cckit | wc -l | tr -d ' ')" "0"
h0="$(git rev-parse HEAD)"
out="$("$CCKIT" init --yes 2>&1 < /dev/null)"
t "init again: rc 0 and no new commit" "$?:$(git rev-parse HEAD)" "0:$h0"
has "init again: the commit step is skipped" "$out" "[skipped] cckit files commit — already committed"

out="$("$CCKIT" task new --kind post "Spring newsletter" 2>&1)"; t "task new: rc 0" "$?" "0"
id="$(printf '%s\n' "$out" | sed -n 's/^✓ task \([a-z0-9]*\) .*/\1/p')"
has "task new: prints the id" "$out" "✓ task $id · Spring newsletter"

out="$("$CCKIT" task start "$id" 2>&1)"; t "task start: rc 0" "$?" "0"
wt="$(printf '%s\n' "$out" | tail -1 | cut -d'|' -f1)"
t "task start: the task's folder has CLAUDE.md" "$([ -f "$wt/CLAUDE.md" ] && echo yes || echo no)" "yes"
t "task start: the task's folder has the cckit config" "$([ -f "$wt/.claude/kit.config.json" ] && echo yes || echo no)" "yes"
t "task start: the task's folder has the rules" "$([ -f "$wt/.claude/rules/plain-language.md" ] && echo yes || echo no)" "yes"
t "task start: the worktree does not show as untracked" "$(git status --porcelain)" ""

echo "Dear reader" > "$wt/newsletter.md"
out="$(cd "$wt" && "$CCKIT" task finish "$id" "First draft of the spring newsletter" --all 2>&1)"; t "task finish: rc 0" "$?" "0"
has "task finish: prints the review link" "$out" "✓ https://github.com/tester/site/pull/1"
t "task finish: the new file is on the task's branch on origin" \
  "$(git -C "$p.git" ls-tree -r --name-only "light/$id-spring-newsletter" -- newsletter.md)" "newsletter.md"

: > "$GH_LOG"
out="$("$CCKIT" status 2>&1)"; t "status: rc 0" "$?" "0"
has "status: has the light-task section" "$out" "## Light tasks"
has "status: counts the task as waiting for review" "$out" "review: 1   doing: 0   todo: 0   draft: 0"
has "status: lists the task" "$out" "| \`$id\` | **review** | Spring newsletter |"
js="$("$CCKIT" status --llm 2>/dev/null)"
t "status --llm: the task is in attention" "$(printf '%s' "$js" | jq -r '.light_tasks.attention[0] | .id + " " + .state')" "$id review"
t "status --llm: the count" "$(printf '%s' "$js" | jq -r '.light_tasks.counts.review')" "1"
t "status: no gh call names the task" "$(grep -c -e "$id" -e 'light/' "$GH_LOG" | tr -d ' ')" "0"

# ── 8. no absolute home-directory path in what cckit ships ──────────────────────────────────────
hits="$(grep -rlE '/(Users|home)/[a-z][a-z0-9_-]+/' "$ROOT/commands" "$ROOT/skills" "$ROOT/templates" 2>/dev/null | sed "s#^$ROOT/##" | tr '\n' ' ')"
t "no command, skill or template holds a home-directory path" "$hits" ""
has "kit-update reads the plugin version through the documented variable" \
  "$(cat "$ROOT/commands/kit-update.md")" '"${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json"'

[ "$fail" -eq 0 ] && echo "marketing-walkthrough-test: PASS" || echo "marketing-walkthrough-test: FAIL"
exit "$fail"
