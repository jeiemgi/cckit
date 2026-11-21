#!/usr/bin/env bash
# shellcheck shell=bash
# light-task-test.sh — `cckit task <new|list|next|start|finish|share>` end to end (#450), against a
# stubbed gh, a throwaway repo and a bare remote. Covers every verb in human and `--llm` form, the
# derived states (draft → doing → review → done; shared), the move of a draft onto its branch, the pull
# request `finish` opens (no `Closes`, title ending in the task id), the gc protection of a live
# `light/<id>-<slug>` branch and its release once the task is done on the base branch, a second
# clone refused on a task already taken, two branches adding tasks merging without a conflict, and
# the source interface (an unknown source refused, a second source reached through the dispatcher).
# Run: bash scripts/lib/light-task-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
set -u
LIB="$(cd "$(dirname "$0")" && pwd)"
CCKIT="$(cd "$LIB/../.." && pwd)/bin/cckit"
# shellcheck source=/dev/null
. "$LIB/test-env.sh" && test_env_seal
unset CLAUDE_CODE_REMOTE CCKIT_GH_TRANSPORT
fail=0
t()   { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
has() { case "$2" in *"$3"*) echo "ok: $1" ;; *) echo "FAIL: $1 -> '[$2]' lacks '[$3]'"; fail=1 ;; esac; }
hasnt() { case "$2" in *"$3"*) echo "FAIL: $1 -> '[$2]' has '[$3]'"; fail=1 ;; *) echo "ok: $1" ;; esac; }
command -v jq >/dev/null 2>&1 || { echo "light-task-test: jq required" >&2; exit 1; }

tmp="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$tmp"' EXIT
export GH_LOG="$tmp/gh.log" GH_OPEN_URL="" GH_PR_INDEX=""
: > "$GH_LOG"
mkdir -p "$tmp/bin"
# A gh that logs one call per line (newlines in a body become \036). `pr list --head` answers the
# open-PR lookup; a bare `pr list` answers gc's PR index.
cat > "$tmp/bin/gh" <<'SH'
#!/usr/bin/env bash
{ printf '%s' "$*" | tr '\n' '\036'; echo; } >> "$GH_LOG"
case "$1 $2" in
  "pr list")
    case " $* " in
      *" --head "*) [ -n "$GH_OPEN_URL" ] && echo "$GH_OPEN_URL" ;;
      *) [ -n "$GH_PR_INDEX" ] && printf '%b' "$GH_PR_INDEX" ;;
    esac ;;
  "pr create") [ -n "${GH_CREATE_FAIL:-}" ] && exit 1; echo "https://github.com/o/r/pull/77" ;;
  "issue view") echo "issue lookups are not expected for a light task" >&2; exit 1 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH" KIT_WT_INSTALL=0

git init -q --bare "$tmp/remote.git"
git clone -q "$tmp/remote.git" "$tmp/work" 2>/dev/null
cd "$tmp/work" || exit 1
git config user.email t@t; git config user.name t
cat > cckit.config.json <<'JSON'
{"kitVersion":"0.0.0","project":{"name":"x","slug":"x","owner":"o","language":"en"},"profile":"p",
 "github":{"repo":"o/r","owner":"o","baseBranch":"develop","projectsV2":false}}
JSON
echo "hello" > page.txt
echo ".claude/worktrees/" > .gitignore
git add -A; git commit -q -m init; git branch -M develop; git push -q origin develop 2>/dev/null
W="$tmp/work"

# ── new ─────────────────────────────────────────────────────────────────────────────────────────
out="$("$CCKIT" task new "Write the spring newsletter" 2>&1)"; t "new exits 0" "$?" "0"
A="$(printf '%s\n' "$out" | sed -n 's/^✓ task \([a-z0-9]*\) .*/\1/p')"
has "new prints the id and the title" "$out" "✓ task $A · Write the spring newsletter"
has "new prints the start command" "$out" "cckit task start $A"
t "new writes one file per task" "$(sed -n 1,3p "tasks/$A.md" | tr '\n' '|')" "id: $A|title: Write the spring newsletter|status: todo|"
case "$A" in t[0-9a-f][0-9a-f][0-9a-f][0-9a-f]) echo "ok: the id starts with a letter" ;; *) echo "FAIL: id '$A'"; fail=1 ;; esac
out="$("$CCKIT" task new --priority p1 --body "Two posts" "Plan the launch posts" --llm)"
B="$(printf '%s' "$out" | jq -r .id)"
t "new --llm is one JSON object" "$(printf '%s' "$out" | jq -r '[.verb, .ok, .file] | join(" ")')" "task new true tasks/$B.md"
has "new keeps the body after a blank line" "$(cat "tasks/$B.md")" "created: $(date +%Y-%m-%d)

Two posts"
"$CCKIT" task new >/dev/null 2>&1; t "new without a title is a usage error" "$?" "2"
"$CCKIT" task new --priority high "x" >/dev/null 2>&1; t "new refuses a priority outside p0-p3" "$?" "2"

# ── list / next ─────────────────────────────────────────────────────────────────────────────────
out="$("$CCKIT" task list 2>&1)"
t "list shows both drafts" "$(printf '%s\n' "$out" | grep -c ' draft ')" "2"
t "list orders by priority inside a state" "$(printf '%s\n' "$out" | sed -n 2p | cut -d' ' -f1)" "$B"
out="$("$CCKIT" task list --llm)"
t "list --llm is a JSON array of tasks" "$(printf '%s' "$out" | jq -r '[.[] | .id + ":" + .state] | sort | join(",")')" \
  "$(printf '%s\n%s\n' "$A:draft" "$B:draft" | sort | tr '\n' ',' | sed 's/,$//')"
t "list --llm reports no branch as null" "$(printf '%s' "$out" | jq -r '.[0].branch')" "null"
out="$("$CCKIT" task next 2>&1)"
has "next names the highest-priority task" "$out" "next: $B · Plan the launch posts (p1)"
has "next prints the start command" "$out" "cckit task start $B"
t "next --llm carries the start command" "$("$CCKIT" task next --llm | jq -r .start)" "cckit task start $B"

# ── start ───────────────────────────────────────────────────────────────────────────────────────
out="$("$CCKIT" task start "$A" 2>"$tmp/start.err")"; t "start exits 0" "$?" "0"
WT="$W/.claude/worktrees/light+$A-write-the-spring-newsletter"
BR="light/$A-write-the-spring-newsletter"
t "start prints worktree|branch|id" "$out" "$WT|$BR|$A"
t "the worktree is on the task branch" "$(git -C "$WT" rev-parse --abbrev-ref HEAD)" "$BR"
t "the branch is cut from origin/develop" "$(git -C "$WT" merge-base HEAD origin/develop)" "$(git rev-parse origin/develop)"
t "the draft is committed on the branch" "$(git -C "$WT" show "HEAD:tasks/$A.md" | sed -n 2p)" "title: Write the spring newsletter"
[ -f "$W/tasks/$A.md" ] && { echo "FAIL: the draft was left untracked in the starting checkout"; fail=1; } || echo "ok: the draft moved off the starting checkout"
[ -f "$W/tasks/$B.md" ] && echo "ok: the other draft stays" || { echo "FAIL: start removed another task's draft"; fail=1; }
t "the branch is pushed" "$(git ls-remote --heads "$tmp/remote.git" "$BR" | grep -c .)" "1"
has "start says how to finish" "$(cat "$tmp/start.err")" "cckit task finish $A"
t "list shows the task as doing" "$("$CCKIT" task list --llm | jq -r --arg id "$A" '.[] | select(.id == $id) | .state + " " + .branch')" "doing $BR"
out="$("$CCKIT" task take "${A%??}" 2>&1 | tail -1)"
t "take is start, an id prefix resolves, a re-run reuses the worktree" "$out" "$WT|$BR|$A"
"$CCKIT" task start nope >/dev/null 2>&1; t "start refuses an unknown task" "$?" "1"
out="$("$CCKIT" task start "$B" --no-push --llm)"
t "start --llm reports the worktree" "$(printf '%s' "$out" | jq -r '[.verb, .ok, .id, .branch] | join(" ")')" \
  "task start true $B light/$B-plan-the-launch-posts"
WTB="$(printf '%s' "$out" | jq -r .worktree)"
t "--no-push leaves the branch local" "$(git ls-remote --heads "$tmp/remote.git" "light/$B-*" | grep -c .)" "0"
t "the starting checkout is clean again" "$(git -C "$W" status --porcelain)" ""

# ── gc protection ───────────────────────────────────────────────────────────────────────────────
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || { echo "skip: $sh not installed"; continue; }
  out="$("$sh" -c '. "$1/worktree-issue.sh"
    printf "%s|" "$(wt_task_id light/t3f9a-spring-news)" "$(wt_task_id /x/.claude/worktrees/light+t3f9a-spring-news)" \
      "$(wt_issue_number light/t3f9a-spring-news)" "$(wt_task_id feat/12-x)" "$(wt_task_id light/12-x)" \
      "$(wt_task_id light/t3f9a)" "$(wt_task_id light/T3-x)" "$(wt_issue_number light/t12a-x)"' _ "$LIB")"
  t "wt_task_id parses the light forms only, and no issue number leaks ($sh)" "$out" "t3f9a|t3f9a|||||||"
done
out="$(cd "$W" && . "$LIB/kit-config.sh" && load_kit_config && . "$LIB/kit-gc.sh" && _kit_gc_load_deps \
  && _kit_gc_classify "$BR" "" o/r; wt_protected_reason "$BR" o/r; echo; wt_protected_reason "$WT" o/r)"
has "gc classifies a live light branch PROTECTED" "$out" "PROTECTED: light task $A still OPEN"
has "wt_protected_reason protects the worktree path too" "$(printf '%s\n' "$out" | tail -1)" "light task $A still OPEN"
out="$("$CCKIT" gc 2>/dev/null)"
has "cckit gc keeps a started task (no commit beyond base would otherwise read LANDED)" \
  "$(printf '%s\n' "$out" | grep "  light/$B-")" "PROTECTED: light task $B still OPEN"
hasnt "cckit gc offers no light branch for deletion" "$(printf '%s\n' "$out" | grep 'light/')" "> LANDED"
t "gc never asked GitHub about an issue for a light branch" "$(grep -c '^issue view' "$GH_LOG")" "0"
out="$(cd "$W" && KIT_TASKS_SOURCE=nosuch bash -c '. "$1/worktree-issue.sh"; wt_task_state t3f9a light/t3f9a-x; wt_protected_reason light/t3f9a-x' _ "$LIB")"
t "a source that cannot be read is unknown, and unknown is kept" "$out" "unknown
light task t3f9a state unknown"

# ── finish ──────────────────────────────────────────────────────────────────────────────────────
echo "spring" >> "$WT/page.txt"; echo "draft" > "$WT/new-post.txt"
: > "$GH_LOG"
out="$(cd "$WT" && "$CCKIT" task finish "Newsletter copy for the spring issue" 2>"$tmp/fin.err")"; t "finish exits 0" "$?" "0"
t "finish prints the PR url" "$out" "✓ https://github.com/o/r/pull/77"
t "the branch copy says done" "$(git -C "$WT" show "HEAD:tasks/$A.md" | sed -n 3p)" "status: done"
t "the work is committed with the task" "$(git -C "$WT" show --stat --format= HEAD | grep -c 'page.txt')" "1"
has "a new file is reported, not committed" "$(cat "$tmp/fin.err")" "new-post.txt"
t "the new file stays untracked without --all" "$(git -C "$WT" ls-files new-post.txt | grep -c .)" "0"
t "the pushed branch carries the done mark" "$(git --git-dir="$tmp/remote.git" show "$BR:tasks/$A.md" | sed -n 3p)" "status: done"
create="$(grep '^pr create' "$GH_LOG")"
has "the PR targets the base branch" "$create" "--base develop --head $BR"
has "the PR title is a Conventional Commit subject ending in the task id" "$create" "--title feat: Write the spring newsletter [$A]"
has "the PR body names the task" "$create" "\`$A\` · Write the spring newsletter"
hasnt "the PR body has no Closes line" "$create" "Closes #"
t "list shows the task in review" "$("$CCKIT" task list --llm | jq -r --arg id "$A" '.[] | select(.id == $id) | .state')" "review"
: > "$GH_LOG"
out="$(GH_OPEN_URL="https://github.com/o/r/pull/77" "$CCKIT" task done "$A" "again" --all --llm)"
t "done is finish; --llm reports the url" "$(printf '%s' "$out" | jq -r '[.verb, .ok, .url] | join(" ")')" "task finish true https://github.com/o/r/pull/77"
t "an open PR is reported, not re-created" "$(grep -c '^pr create' "$GH_LOG")" "0"
t "--all commits new files" "$(git -C "$WT" ls-files new-post.txt | grep -c .)" "1"
"$CCKIT" task finish "$B" >/dev/null 2>&1; t "finish without a summary is a usage error" "$?" "2"
"$CCKIT" task finish zz9 "x" >/dev/null 2>&1; t "finish refuses an unknown task" "$?" "1"
has "the default PR body uses the code wording" "$create" "its diff carries the task record"
# pr.bodyStyle = content (#418): task B is finished under a config that sets it.
# plainLanguage.enabled (#420) is set in the same config: the progress lines drop the git words.
jq '.pr = {bodyStyle: "content"} | .plainLanguage = {enabled: true}' "$W/cckit.config.json" > "$tmp/content.config.json"
: > "$GH_LOG"
out="$(cd "$WTB" && KIT_CONFIG="$tmp/content.config.json" "$CCKIT" task finish "fix: launch posts scheduled" 2>"$tmp/fin-plain.err")"
t "plain language: stdout is still the PR url line" "$out" "✓ https://github.com/o/r/pull/77"
has "plain language: finish says it is ready for review" "$(cat "$tmp/fin-plain.err")" "[task] ready for review — open the link and approve it there"
has "the default wording names the worktree" "$(cat "$tmp/start.err")" "created worktree"
pl="$(KIT_CONFIG="$tmp/content.config.json" "$CCKIT" task new "Plain wording probe" 2>&1)"
has "plain language: new says where the file is, without 'checkout'" "$pl" "only on this computer until you start it or share the list"
hasnt "plain language: new does not say checkout" "$pl" "checkout"
plid="$(printf '%s\n' "$pl" | sed -n 's/^✓ task \([a-z0-9]*\) .*/\1/p')"
plout="$(KIT_CONFIG="$tmp/content.config.json" "$CCKIT" task start --no-push "$plid" 2>"$tmp/start-plain.err")"; t "plain language: start exits 0" "$?" "0"
t "plain language: start's stdout keeps the <worktree>|<branch>|<id> shape" "${plout##*|}" "$plid"
has "plain language: start says the draft is started" "$(cat "$tmp/start-plain.err")" "[$plid] started — the draft lives in "
has "plain language: start says how to send it for review" "$(cat "$tmp/start-plain.err")" "when the draft is ready for review: cckit task finish $plid \"<summary>\" --all"
hasnt "the default wording's finish hint does not add --all" "$(cat "$tmp/start.err")" "<summary>\" --all"
hasnt "plain language: start does not say 'created worktree'" "$(cat "$tmp/start-plain.err")" "created worktree"
hasnt "plain language: start does not name the branch" "$(cat "$tmp/start-plain.err")" "(branch "
create="$(grep '^pr create' "$GH_LOG")"
has "a conventional summary becomes the PR title, with the id" "$create" "--title fix: launch posts scheduled [$B]"
has "content body: names the task" "$create" "\`$B\` · "
has "content body: review checklist" "$create" "Read the draft from start to finish"
has "content body: says what approving does" "$create" "Approving and merging this pull request marks the task done"
hasnt "content body: no 'diff'" "$create" "diff"
hasnt "content body: no Closes line" "$create" "Closes #"

# ── the PR merges: the task is done, and gc lets the branch go ──────────────────────────────────
git clone -q "$tmp/remote.git" "$tmp/merger" 2>/dev/null
( cd "$tmp/merger" && git config user.email t@t && git config user.name t && git checkout -q develop \
  && git merge -q --squash "origin/$BR" >/dev/null 2>&1 && git commit -q -m "feat: Write the spring newsletter [$A] (#77)" \
  && git push -q origin develop ) 2>/dev/null
out="$("$CCKIT" task list --all --llm)"
t "after the merge the task is done" "$(printf '%s' "$out" | jq -r --arg id "$A" '.[] | select(.id == $id) | .state')" "done"
t "list without --all hides it" "$("$CCKIT" task list --llm | jq -r --arg id "$A" '[.[] | select(.id == $id)] | length')" "0"
"$CCKIT" task start "$A" >/dev/null 2>&1; t "start refuses a done task" "$?" "1"
out="$(cd "$W" && . "$LIB/kit-config.sh" && load_kit_config && . "$LIB/kit-gc.sh" && _kit_gc_load_deps \
  && wt_task_state "$A" "$BR" && _kit_gc_classify "$BR" "$(printf '%s\tPR#77 MERGED' "$BR")" o/r)"
has "a done task reads closed" "$out" "closed"
has "gc offers the branch once its PR merged" "$out" "SAFE (PR#77 MERGED"

# ── a second clone: the task is visible, and a taken task is refused ────────────────────────────
git -C "$WTB" push -q -u origin "light/$B-plan-the-launch-posts" 2>/dev/null
git clone -q "$tmp/remote.git" "$tmp/mate" 2>/dev/null
cd "$tmp/mate" || exit 1
git config user.email m@m; git config user.name m; git checkout -q develop
t "a teammate's list shows the pushed task in review" "$("$CCKIT" task list --llm | jq -r --arg id "$B" '.[] | select(.id == $id) | .state')" "review"
out="$("$CCKIT" task start "$B" 2>&1)"; t "a task taken on origin is refused" "$?" "1"
has "the refusal names the branch and --force" "$out" "cckit task start --force $B"
out="$("$CCKIT" task start --force "$B" 2>/dev/null)"
t "--force continues the branch in a worktree here" "$(git -C "${out%%|*}" rev-parse HEAD)" "$(git --git-dir="$tmp/remote.git" rev-parse "light/$B-plan-the-launch-posts")"

# ── share ───────────────────────────────────────────────────────────────────────────────────────
C="$("$CCKIT" task new "Brief the designer" --llm | jq -r .id)"
D="$("$CCKIT" task new "Book the venue" --llm | jq -r .id)"
: > "$GH_LOG"
out="$("$CCKIT" task share "Q1 backlog" 2>/dev/null)"; t "share exits 0" "$?" "0"
t "share prints the PR url" "$out" "✓ https://github.com/o/r/pull/77"
SB="$(git for-each-ref --format='%(refname:short)' 'refs/heads/light/share-*')"
t "the share branch carries both tasks and nothing else" "$(git diff --name-only origin/develop "$SB" | sort | tr '\n' ' ')" \
  "$(printf 'tasks/%s.md\ntasks/%s.md\n' "$C" "$D" | sort | tr '\n' ' ')"
has "the share PR title counts the tasks" "$(grep '^pr create' "$GH_LOG")" "--title chore(tasks): add 2 tasks [share-"
t "share leaves the checkout clean" "$(git status --porcelain)" ""
t "shared tasks stay listed, as shared, on the share branch" "$("$CCKIT" task list --llm | jq -r --arg id "$C" '.[] | select(.id == $id) | .state + " " + .branch')" "shared $SB"
t "next does not offer a shared task" "$("$CCKIT" task next --llm | jq -r --arg c "$C" --arg d "$D" 'if . == null then "none" elif .id == $c or .id == $d then "shared" else "other" end')" "none"
out="$("$CCKIT" task start "$C" 2>&1)"; t "start refuses a task whose share PR has not merged" "$?" "1"
has "the refusal names the share branch" "$out" "share pull request ($SB)"
[ -d "$tmp/mate/.claude/worktrees/light+$C-brief-the-designer" ] && { echo "FAIL: the refused start left a worktree"; fail=1; } || echo "ok: the refused start made no worktree"
: > "$GH_LOG"
out="$(GH_OPEN_URL="https://github.com/o/r/pull/77" "$CCKIT" task share 2>/dev/null)"
t "share with no new drafts reports the open share PR" "$out" "✓ https://github.com/o/r/pull/77"
t "and does not create a second one" "$(grep -c '^pr create' "$GH_LOG")" "0"
# The share PR merges: the tasks are todo, and a share with nothing pending is a no-op.
( cd "$tmp/merger" && git fetch -q origin && git checkout -q develop && git pull -q origin develop \
  && git merge -q --squash "origin/$SB" >/dev/null 2>&1 && git commit -q -m "chore(tasks): add 2 tasks (#78)" \
  && git push -q origin develop ) 2>/dev/null
t "after the share PR merges the task is todo" "$("$CCKIT" task list --llm | jq -r --arg id "$C" '.[] | select(.id == $id) | .state')" "todo"
t "share with nothing pending is a no-op" "$("$CCKIT" task share 2>&1)" "(no drafts to share in this checkout)"
# A share whose pull request could not be opened keeps its tasks listed, and a re-run retries it.
G="$("$CCKIT" task new "Order the banners" --llm | jq -r .id)"
out="$(GH_CREATE_FAIL=1 "$CCKIT" task share 2>&1)"; t "share exits 1 when the PR cannot be opened" "$?" "1"
has "the failure says how to retry" "$out" "run the same command again to retry"
t "the task of a failed share is still listed" "$("$CCKIT" task list --llm | jq -r --arg id "$G" '.[] | select(.id == $id) | .state')" "shared"
: > "$GH_LOG"
out="$("$CCKIT" task share --llm)"
t "re-running share opens the PR for the pending branch" "$(printf '%s' "$out" | jq -r '[.verb, .ok, .url] | join(" ")')" "task share true https://github.com/o/r/pull/77"
has "the retried PR lists the pending task" "$(grep '^pr create' "$GH_LOG")" "\`$G\`"
out="$(cd "$WTB" && GH_CREATE_FAIL=1 "$CCKIT" task finish "fix: launch posts scheduled" 2>&1)"; t "finish exits 1 when the PR cannot be opened" "$?" "1"
has "finish says the branch is pushed and how to retry" "$out" "the branch is pushed; run the same command again to retry"
t "the share branch is not a task" "$(. "$LIB/kit-config.sh" && load_kit_config && . "$LIB/worktree-issue.sh" && wt_protected_reason "$SB" o/r)" ""

# ── two branches each add a task: the merge is clean ────────────────────────────────────────────
git checkout -q -b feat/1-a origin/develop
E="$("$CCKIT" task new "Task on branch a" --llm | jq -r .id)"; git add -A; git commit -q -m "a"
git checkout -q -b feat/2-b origin/develop
F="$("$CCKIT" task new "Task on branch b" --llm | jq -r .id)"; git add -A; git commit -q -m "b"
git merge -q feat/1-a -m "merge a" >/dev/null 2>&1; t "two branches that each add a task merge without a conflict" "$?" "0"
t "both task files are present after the merge" "$(ls tasks | grep -c -e "^$E.md" -e "^$F.md")" "2"

# ── the source interface ────────────────────────────────────────────────────────────────────────
out="$(KIT_TASKS_SOURCE=monday "$CCKIT" task list 2>&1)"; t "an unknown source is refused" "$?" "1"
has "the refusal names the file a source lives in" "$out" "scripts/lib/task-source-monday.sh"
out="$(. "$LIB/task-source.sh"; . "$LIB/worktree-issue.sh"
  task_fake_state() { [ "$1" = t9 ] && echo open; return 0; }
  KIT_TASKS_SOURCE=fake; export KIT_TASKS_SOURCE
  wt_protected_reason light/t9-anything)"
t "a second source is reached through the dispatcher alone" "$out" "light task t9 still OPEN"
t "tasks.dir is read from the config" "$(cd "$tmp/mate" && git checkout -q develop 2>/dev/null; jq '.tasks.dir = "work/todo"' cckit.config.json > c.tmp && mv c.tmp cckit.config.json
  id="$("$CCKIT" task new "Elsewhere" --llm | jq -r .id)"; [ -f "work/todo/$id.md" ] && echo yes)" "yes"

# ── tasks.default: which list is the project's default (#422) ───────────────────────────────────
cd "$tmp/mate" || exit 1
t "task default: issues when the key is absent" "$("$CCKIT" task default)" "issues"
jq '.tasks.default = "light"' cckit.config.json > c.tmp && mv c.tmp cckit.config.json
t "task default: light when the config says so" "$("$CCKIT" task default)" "light"
t "task default --llm" "$("$CCKIT" task default --llm | jq -r '[.verb, .default] | join(" ")')" "task default light"
want="$(KIT_TASK_FETCH=0 "$CCKIT" task next)"
t "a bare cckit next answers from the light list" "$(KIT_TASK_FETCH=0 "$CCKIT" next 2>/dev/null)" "$want"
has "…and names the command that starts the task" "$want" "start: cckit task start "
t "cckit next --llm is the light task object" "$(KIT_TASK_FETCH=0 "$CCKIT" next --llm 2>/dev/null | jq -r 'has("start")')" "true"
: > "$GH_LOG"
KIT_TASK_FETCH=0 "$CCKIT" next >/dev/null 2>&1
t "the light next makes no gh call" "$(grep -c . "$GH_LOG" | tr -d ' ')" "0"
jq '.tasks.default = "sometimes"' cckit.config.json > c.tmp && mv c.tmp cckit.config.json
out="$("$CCKIT" task default 2>"$tmp/default.err")"
t "an unknown tasks.default reads as issues" "$out" "issues"
has "…with a warning naming the value" "$(cat "$tmp/default.err")" "tasks.default 'sometimes' is neither 'light' nor 'issues'"

# ── #487: a base branch the repository does not have; the `draft` state in plain language ───────
nb="$tmp/nobase"; mkdir -p "$nb"; cd "$nb" || exit 1
git init -q; git symbolic-ref HEAD refs/heads/trunk; git config user.email t@t; git config user.name t
cat > cckit.config.json <<'JSON'
{"kitVersion":"0.0.0","project":{"name":"x","slug":"x","owner":"o","language":"en"},"profile":"p",
 "github":{"repo":"o/r","owner":"o","baseBranch":"develop","projectsV2":false},"plainLanguage":{"enabled":true}}
JSON
echo ".claude/worktrees/" > .gitignore; git add -A; git commit -q -m init
N="$("$CCKIT" task new "No base yet" --llm | jq -r .id)"
out="$("$CCKIT" task start "$N" 2>&1)"; t "start without the base branch: rc 1" "$?" "1"
has "…names the missing branch" "$out" "no base branch 'develop' to cut from"
has "…names the config key" "$out" "github.baseBranch"
has "…names the command that creates it" "$out" "cckit init --yes"
has "…names the branch the folder is on" "$out" "this folder is on 'trunk'"
t "…and made no worktree" "$([ -e .claude/worktrees ] && echo yes || echo no)" "no"
out="$(KIT_TASK_FETCH=0 "$CCKIT" task list 2>&1)"
has "plain language: list still prints the state the source reports" "$out" "$N   draft"
has "plain language: list says what draft means there" "$out" "draft = the task is on this computer only"
jq 'del(.plainLanguage)' cckit.config.json > c.tmp && mv c.tmp cckit.config.json
out="$(KIT_TASK_FETCH=0 "$CCKIT" task list 2>&1)"
case "$out" in *"draft = "*) echo "FAIL: the legend is printed without plain language"; fail=1 ;; *) echo "ok: no legend without plain language" ;; esac

[ "$fail" -eq 0 ] && echo "PASS light-task-test" || echo "FAIL light-task-test"
exit "$fail"
