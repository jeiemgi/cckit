#!/usr/bin/env bash
# shellcheck shell=bash
# update-path-test.sh — the documented update path, end to end (#448).
#
# Builds a project the way an OLDER cckit left it (a `task-*` skill dir, a config at an earlier
# kitVersion in the project's own formatting, a tracked settings.json that predates the mail hook),
# adds the customizations a real project has (an edited rule, hook, script and CLAUDE.md, paths
# registered under `upgrade.removed`), and runs the path docs-site/src/content/docs/update.mdx
# gives a user, through bin/cckit:
#
#   cckit update  ->  cckit migrate  ->  cckit init --upgrade --dry-run  ->  cckit init --upgrade
#   ->  cckit update  ->  cckit init --upgrade (again)
#
# It asserts the five defects a trial run on a real project found (the issue's comment) stay fixed:
#   1. the dry run's list IS the real run's list — both equal an independent before/after checksum
#      of the whole tree;
#   2. a version bump changes ONE line of the config;
#   3. `cckit update` names `cckit init --upgrade`, not only the slash command;
#   4. (cckit doctor installing with no flag is covered in kit-doctor-test.sh);
#   5. a settings.json the upgrade merges into is reported modified, not preserved, and a hook
#      registration the project arranged is not moved.
# And: customizations kept, removed paths not re-added, a second run changes nothing, and every
# command on the docs page is one this file runs.
#
# Network-free: the upgrade path skips the doctor preflight; every value gh would be asked for is in
# the fixture config. Everything lives under one mktemp dir. Run:  bash scripts/update-path-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/scripts/lib/test-env.sh" && test_env_seal
CCKIT="$ROOT/bin/cckit"
PAGE="$ROOT/docs-site/src/content/docs/update.mdx"
fail=0
t()     { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
has()   { if printf '%s' "$2" | grep -qF -- "$3"; then echo "ok: $1"; else echo "FAIL: $1 -> '$3' not in: $2"; fail=1; fi; }
hasnt() { if printf '%s' "$2" | grep -qF -- "$3"; then echo "FAIL: $1 -> '$3' found in: $2"; fail=1; else echo "ok: $1"; fi; }

command -v jq   >/dev/null 2>&1 || { echo "update-path-test: jq absent — skipping";   exit 0; }
command -v git  >/dev/null 2>&1 || { echo "update-path-test: git absent — skipping";  exit 0; }
command -v perl >/dev/null 2>&1 || { echo "update-path-test: perl absent — skipping"; exit 0; }

INSTALLED="$(jq -r '.version // "0.0.0"' "$ROOT/.claude-plugin/plugin.json")"
OLD="0.0.7"   # any version below the installed one
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
tmp="$(cd "$tmp" && pwd)"
proj="$tmp/sample-app"; mkdir -p "$proj"
export KIT_ASSUME_YES=1 KIT_ASCII=1 NO_COLOR=1
unset CLAUDE_PLUGIN_ROOT

# tree <file> — "<path>\t<cksum>" for EVERY file of the project outside .git. Independent of the
# measurement init.sh itself takes (scripts/lib/upgrade-report.sh), which is the thing under test.
tree() {
  ( cd "$proj" && find . -name .git -prune -o -type f -print | LC_ALL=C sort | while IFS= read -r f; do
      printf '%s\t%s\n' "${f#./}" "$(cksum < "$f" | tr ' ' ':')"
    done ) > "$1"
}
# delta <before> <after> — "A <path>" / "M <path>" lines, sorted by path.
delta() {
  awk -F'\t' 'NR==FNR { b[$1]=$2; next } !($1 in b) { print "A " $1; next } b[$1] != $2 { print "M " $1 }' "$1" "$2" \
    | LC_ALL=C sort -k2
}
# block <output> <heading> — the "A path" / "M path" rows init.sh printed under <heading>.
block() {
  printf '%s\n' "$1" | awk -v h="$2" '
    index($0, "  " h " (") == 1 { on = 1; next }
    on && /^    [AMD] / { sub(/^    /, ""); print; next }
    on { on = 0 }' | LC_ALL=C sort -k2
}
commit() { git -C "$proj" add -A >/dev/null 2>&1 && git -C "$proj" commit -q -m "$1" >/dev/null 2>&1; }

# ── the fixture: a project as an older cckit left it ───────────────────────────────────────────
git -C "$proj" init -q
git -C "$proj" config user.email fixture@example.invalid
git -C "$proj" config user.name  fixture
git -C "$proj" config commit.gpgsign false
mkdir -p "$proj/.claude/skills/task-pr" "$proj/.claude/rules" "$proj/.claude/hooks" "$proj/scripts"

# The config in the project's OWN formatting: inline arrays, and `review` / `nightGrant` (keys no
# template writes) ahead of `milestones`. jq would expand the arrays and reorder nothing here, so a
# whole-file rewrite shows up as many changed lines.
cat > "$proj/.claude/kit.config.json" <<JSON
{
  "kitVersion": "$OLD",
  "profile": "minimal",
  "project": { "name": "Sample App", "slug": "sample-app", "owner": "sample-owner", "language": "English", "path": "$proj" },
  "roles": ["PM", "Generalist"],
  "github": { "repo": "example/sample-app", "owner": "example", "baseBranch": "develop", "projectsV2": false, "projectNumber": null, "projectTitle": "Sample App" },
  "review": { "bots": ["one", "two"], "required": 1 },
  "nightGrant": { "waves": [1, 2] },
  "milestones": ["Backlog", "Doing", "Done"],
  "knowledge": { "dir": "knowledge" },
  "upgrade": {
    "removed": [".claude/rules/task-management.md", "scripts/task-sync.sh"]
  }
}
JSON
CFG_BEFORE="$(jq -S . "$proj/.claude/kit.config.json")"

# Old layout: a bare `task-*` skill (v2 names it `kit-task-*`) and a CLAUDE.md that refers to it.
printf 'the project edited this skill\n' > "$proj/.claude/skills/task-pr/SKILL.md"
printf '# Sample App\n\nOPERATOR-NOTE: open the PR with /task-pr.\n' > "$proj/CLAUDE.md"
# Customizations an upgrade must keep.
printf '# Communication\n\nOPERATOR-NOTE: answer in two lines.\n' > "$proj/.claude/rules/communication-style.md"
printf '#!/usr/bin/env bash\n# OPERATOR-NOTE: our own hygiene report\nexit 0\n' > "$proj/.claude/hooks/repo-hygiene.sh"
chmod +x "$proj/.claude/hooks/repo-hygiene.sh"
printf '#!/usr/bin/env bash\n# OPERATOR-NOTE: our own labels\n' > "$proj/scripts/setup-labels.sh"
# A tracked settings.json from before the mail hook existed. The raw-git guard sits INSIDE a Bash
# block the project shares with its own hook — the arrangement the upgrade used to break up.
cat > "$proj/.claude/settings.json" <<'JSON'
{
  "permissions": { "allow": ["Bash(cckit merge:*)"] },
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [
        { "type": "command", "command": "$CLAUDE_PROJECT_DIR/scripts/own-guard.sh", "timeout": 5 },
        { "type": "command", "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/guard-raw-git-ops.sh", "timeout": 10 }
      ] }
    ]
  }
}
JSON
commit "a project scaffolded by an older cckit"

run() { ( cd "$proj" && "$@" ) 2>&1; }   # every step runs inside the project, as the docs page says

# ── 1. which version is the project on? ────────────────────────────────────────────────────────
out="$(run "$CCKIT" update)"; rc=$?
t "cckit update on a project that is behind -> exit 10" "$rc" "10"
has "…names both versions" "$out" "$OLD -> $INSTALLED"
has "…names the terminal command, not only the slash command" "$out" "cckit init --upgrade"
has "…still names the Claude Code command" "$out" "/kit-update"

# ── 2. old layout -> v2 ────────────────────────────────────────────────────────────────────────
tree "$tmp/t0"
out="$(run "$CCKIT" migrate --dry-run)"; rc=$?
t "cckit migrate --dry-run -> exit 0" "$rc" "0"
tree "$tmp/t1"
t "cckit migrate --dry-run writes nothing" "$(delta "$tmp/t0" "$tmp/t1")" ""
has "…and names the move it would make" "$out" ".claude/skills/task-pr -> .claude/skills/kit-task-pr"
out="$(run "$CCKIT" migrate)"; rc=$?
t "cckit migrate -> exit 0" "$rc" "0"
t "old skill dir moved to its v2 name, content kept" \
  "$([ -e "$proj/.claude/skills/task-pr" ] && echo old-present; cat "$proj/.claude/skills/kit-task-pr/SKILL.md" 2>/dev/null)" \
  "the project edited this skill"
t "the rename is registered so the upgrade never re-adds the old path" \
  "$(jq -r '.upgrade.renamed[".claude/skills/task-pr"] // "MISS"' "$proj/.claude/kit.config.json")" ".claude/skills/kit-task-pr"
t "CLAUDE.md now names the v2 command" "$(grep -c '/kit-task-pr' "$proj/CLAUDE.md")" "1"
rm -rf "$proj"/.claude.bak.*          # the migrate backup; the docs page says to delete or ignore it
out="$(run "$CCKIT" migrate)"
has "a second cckit migrate is a no-op" "$out" "already on v2"
# The config as the project commits it before upgrading: migrate re-serialised it (it added a key).
# Restore the project's formatting so step 4 measures the upgrade's own footprint on the file.
jq -c . "$proj/.claude/kit.config.json" > "$tmp/cfg.min"
perl -0777 -pe 's/\{"kitVersion"/{\n  "kitVersion"/; s/","profile"/",\n  "profile"/; s/\}$/\n}/' "$tmp/cfg.min" > "$proj/.claude/kit.config.json"
t "fixture: the reformatted config is the same value" "$(jq -S . "$proj/.claude/kit.config.json")" "$(jq -S . "$tmp/cfg.min")"
commit "migrate to the v2 layout"
t "git status --short is empty before the upgrade" "$(run git status --short)" ""

# ── 3. the dry run ─────────────────────────────────────────────────────────────────────────────
tree "$tmp/t2"
dry="$(run "$CCKIT" init --upgrade --dry-run)"; rc=$?
t "cckit init --upgrade --dry-run -> exit 0" "$rc" "0"
tree "$tmp/t3"
t "the dry run writes nothing to the project" "$(delta "$tmp/t2" "$tmp/t3")" ""
t "the dry run leaves the tree clean" "$(run git status --short)" ""
dry_list="$(block "$dry" "Would change")"
has "the dry run lists the excluded paths as skipped" "$dry" "- scripts/task-sync.sh"
hasnt "the dry run does not claim it would write an excluded rule" "$dry_list" "task-management.md"
hasnt "the dry run does not claim it would write an excluded script" "$dry_list" "scripts/task-sync.sh"
hasnt "the dry run does not list a customized file it will keep" "$dry_list" "communication-style.md"

# ── 4. the upgrade ─────────────────────────────────────────────────────────────────────────────
real="$(run "$CCKIT" init --upgrade)"; rc=$?
t "cckit init --upgrade -> exit 0" "$rc" "0"
tree "$tmp/t4"
truth="$(delta "$tmp/t3" "$tmp/t4")"
real_list="$(block "$real" "Changed on disk")"
t "the upgrade changed something (the fixture is behind)" "$([ -n "$truth" ] && echo yes || echo no)" "yes"
t "defect 1: the dry run's list equals what the run changed on disk" "$dry_list" "$truth"
t "defect 1: the run's own list equals what it changed on disk" "$real_list" "$truth"
t "the counts in the heading match the list" \
  "$(printf '%s\n' "$real" | grep -F 'Changed on disk (' | sed 's/^ *//')" \
  "Changed on disk ($(printf '%s\n' "$truth" | grep -c '^A ') added, $(printf '%s\n' "$truth" | grep -c '^M ') modified):"

# the config: version current, one line changed, nothing else moved
t "kitVersion is the installed version" "$(jq -r .kitVersion "$proj/.claude/kit.config.json")" "$INSTALLED"
t "defect 2: the config diff is one line removed, one added" \
  "$(git -C "$proj" diff --numstat -- .claude/kit.config.json | awk '{print $1 "/" $2}')" "1/1"
t "…and that line is kitVersion" \
  "$(git -C "$proj" diff -- .claude/kit.config.json | grep -E '^[+-] ' | grep -vc kitVersion)" "0"
t "every other config value is as the project had it" \
  "$(jq -S 'del(.kitVersion, .upgrade.renamed)' "$proj/.claude/kit.config.json")" \
  "$(printf '%s' "$CFG_BEFORE" | jq -S 'del(.kitVersion)')"

# new files arrived
t "a rule new to the project was added" "$([ -f "$proj/.claude/rules/merge-safety.md" ] && echo yes || echo no)" "yes"
t "a hook new to the project was added" "$([ -x "$proj/.claude/hooks/kit-mail-check.sh" ] && echo yes || echo no)" "yes"
has "…and is in the list as added" "$real_list" "A .claude/rules/merge-safety.md"

# customizations kept
for f in CLAUDE.md .claude/rules/communication-style.md .claude/hooks/repo-hygiene.sh scripts/setup-labels.sh; do
  t "customization kept: $f" "$(grep -c 'OPERATOR-NOTE' "$proj/$f")" "1"
  hasnt "…and not in the change list: $f" "$truth" " $f"
done
has "the customized hook is reported as drifted, kept" "$real" "! .claude/hooks/repo-hygiene.sh"
t "the migrated skill is kept" "$(cat "$proj/.claude/skills/kit-task-pr/SKILL.md")" "the project edited this skill"

# removed / renamed paths are not re-added
for f in .claude/rules/task-management.md scripts/task-sync.sh .claude/skills/task-pr; do
  t "not re-added: $f" "$([ -e "$proj/$f" ] && echo present || echo absent)" "absent"
done

# defect 5: settings.json
has "defect 5: settings.json is listed as modified" "$real_list" "M .claude/settings.json"
hasnt "defect 5: …and no longer as preserved" "$real" "= .claude/settings.json"
t "the mail hook was registered" \
  "$(jq '[.hooks | to_entries[] | .value[] | .hooks[] | select(.command | test("kit-mail-check"))] | length' "$proj/.claude/settings.json")" "4"
t "the project's shared Bash block is intact: both hooks, original order" \
  "$(jq -r '.hooks.PreToolUse[0].hooks | map(.command | split("/") | last) | join(",")' "$proj/.claude/settings.json")" \
  "own-guard.sh,guard-raw-git-ops.sh"
t "the raw-git guard is registered once, not moved into a second block" \
  "$(jq '[.hooks.PreToolUse[] | .hooks[] | select(.command | test("guard-raw-git-ops"))] | length' "$proj/.claude/settings.json")/$(jq '.hooks.PreToolUse | length' "$proj/.claude/settings.json")" "1/1"
t "the project's permissions are as they were" "$(jq -c '.permissions.allow' "$proj/.claude/settings.json")" '["Bash(cckit merge:*)"]'

# ── 5. confirm ─────────────────────────────────────────────────────────────────────────────────
out="$(run "$CCKIT" update)"; rc=$?
t "cckit update after the upgrade -> exit 0" "$rc" "0"
has "…and says up to date" "$out" "up to date"
t "git status --short shows the change for review" "$([ -n "$(run git status --short)" ] && echo yes || echo no)" "yes"
t "git diff --stat names the config" "$(run git diff --stat | grep -c 'kit.config.json')" "1"
commit "upgrade to the current cckit"

# ── 6. a second run changes nothing ────────────────────────────────────────────────────────────
tree "$tmp/t5"
out="$(run "$CCKIT" init --upgrade)"; rc=$?
t "second cckit init --upgrade -> exit 0" "$rc" "0"
has "…says there is nothing to upgrade" "$out" "nothing to upgrade"
out="$(run "$CCKIT" init --upgrade --dry-run)"
has "second dry run says the same" "$out" "nothing to upgrade"
tree "$tmp/t6"
t "second run changes no file" "$(delta "$tmp/t5" "$tmp/t6")" ""
t "second run leaves the tree clean" "$(run git status --short)" ""

# ── 7. same version, forced through the upgrade again: still nothing but the version line ──────
# (What a project one release behind sees: every file already there.)
perl -pi -e 's/("kitVersion":\s*")[^"]*/${1}'"$OLD"'/' "$proj/.claude/kit.config.json"
t "fixture: the version is behind again" "$(jq -r .kitVersion "$proj/.claude/kit.config.json")" "$OLD"
commit "pretend to be one release behind"
tree "$tmp/t7"
dry="$(run "$CCKIT" init --upgrade --dry-run)"
real="$(run "$CCKIT" init --upgrade)"
tree "$tmp/t8"
truth="$(delta "$tmp/t7" "$tmp/t8")"
t "converged project: dry run == run == disk" "$(block "$dry" "Would change")|$(block "$real" "Changed on disk")" "$truth|$truth"
t "converged project: tracked change is the config alone" "$(run git status --short | awk '{print $2}' | tr '\n' ' ')" ".claude/kit.config.json "
t "converged project: one line" "$(git -C "$proj" diff --numstat -- .claude/kit.config.json | awk '{print $1 "/" $2}')" "1/1"
has "converged project: settings.json is preserved, and says so" "$real" "= .claude/settings.json"

# ── 8. the docs page names only commands this test runs ────────────────────────────────────────
# Every `cckit …` / `git …` line inside a ```bash fence of the page must appear in this file.
if [ -f "$PAGE" ]; then
  n=0
  while IFS= read -r line; do
    n=$((n + 1))
    if grep -qF -- "\"\$CCKIT\" ${line#cckit }" "$0" || grep -qF -- "run $line" "$0"; then
      echo "ok: docs command is run here: $line"
    else
      echo "FAIL: docs page command not run by this test: $line"; fail=1
    fi
  done <<EOF
$(awk '/^```bash/ { on = 1; next } /^```/ { on = 0 } on && /^(cckit|git) / { sub(/[[:space:]]+#.*$/, ""); print }' "$PAGE" | LC_ALL=C sort -u)
EOF
  t "the docs page has commands to check" "$([ "$n" -ge 6 ] && echo yes || echo no)" "yes"
else
  echo "FAIL: docs page missing: $PAGE"; fail=1
fi

[ "$fail" = "0" ] && echo "ALL OK (update-path)" || { echo "update-path: FAILURES"; exit 1; }
