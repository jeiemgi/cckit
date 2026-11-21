#!/usr/bin/env bash
# shellcheck shell=bash
# upgrade-report-test.sh — unit tests for scripts/lib/upgrade-report.sh (#448). Runs under bash AND zsh.
#
#   upgrade_snapshot / upgrade_changes   the before/after measurement `cckit init --upgrade` prints
#   json_write_minimal                   a JSON write that changes as few lines as the change needs
#
# The end-to-end use of both is scripts/update-path-test.sh. Everything lives under one mktemp dir.
# Run:  bash scripts/lib/upgrade-report-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)

if [ -n "${UPGRADE_REPORT_TEST_INNER:-}" ]; then
  set -u
  sh_name="$UPGRADE_REPORT_TEST_INNER"
  fail=0
  t() { if [ "$2" = "$3" ]; then echo "ok($sh_name): $1"; else echo "FAIL($sh_name): $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
  # shellcheck source=/dev/null
  . "$ROOT/scripts/lib/upgrade-report.sh"
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  p="$tmp/proj"; mkdir -p "$p/.claude/rules" "$p/.claude/worktrees/other/.claude" "$p/scripts/node_modules/x" "$p/src"

  # ── snapshot + changes ───────────────────────────────────────────────────────────────────────
  printf 'one\n'  > "$p/.claude/rules/a.md"
  printf 'keep\n' > "$p/.claude/rules/with space.md"
  printf 'x\n'    > "$p/CLAUDE.md"
  printf 'x\n'    > "$p/scripts/run.sh"
  printf 'x\n'    > "$p/.claude/worktrees/other/.claude/in-another-checkout.md"
  printf 'x\n'    > "$p/scripts/node_modules/x/index.js"
  printf 'x\n'    > "$p/src/app.js"
  upgrade_snapshot "$p" > "$tmp/before"
  t "snapshot lists the kit-managed files, by path" "$(cut -f1 "$tmp/before" | tr '\n' '|')" \
    ".claude/rules/a.md|.claude/rules/with space.md|CLAUDE.md|scripts/run.sh|"
  t "snapshot of a directory with none of the paths is empty, rc 0" "$(upgrade_snapshot "$tmp"; echo "rc=$?")" "rc=0"

  printf 'two\n' > "$p/.claude/rules/a.md"           # modified
  printf 'new\n' > "$p/.claude/rules/b.md"           # added
  mkdir -p "$p/knowledge"; printf 'n\n' > "$p/knowledge/INDEX.md"   # added, a root that was absent
  rm -f "$p/scripts/run.sh"                          # deleted
  printf 'y\n'   > "$p/src/app.js"                   # outside the managed paths
  printf 'y\n'   > "$p/.claude/worktrees/other/.claude/in-another-checkout.md"
  upgrade_snapshot "$p" > "$tmp/after"
  upgrade_changes "$tmp/before" "$tmp/after" > "$tmp/changes"
  t "changes: A / M / D by path, nothing else" "$(tr '\t\n' ' |' < "$tmp/changes")" \
    "M .claude/rules/a.md|A .claude/rules/b.md|A knowledge/INDEX.md|D scripts/run.sh|"
  t "print: heading carries the counts" "$(upgrade_changes_print "$tmp/changes" "Changed on disk" | sed -n 1p)" \
    "  Changed on disk (2 added, 1 modified, 1 deleted):"
  t "print: one row per change" "$(upgrade_changes_print "$tmp/changes" "Changed on disk" | sed -n 2p)" "    M .claude/rules/a.md"
  : > "$tmp/none"
  t "print: no change says so" "$(upgrade_changes_print "$tmp/none" "Would change" | tr '\n' '|')" \
    "  Would change (0 added, 0 modified):|    (nothing)|"

  # ── json_write_minimal ───────────────────────────────────────────────────────────────────────
  # The project's own formatting: inline arrays, its own key order.
  orig() {
    cat > "$tmp/cfg.json" <<'JSON'
{
  "kitVersion": "0.7.1",
  "roles": ["PM", "Generalist"],
  "review": { "bots": ["one", "two"] },
  "note": "a \"quoted\" kitVersion: 0.7.1",
  "milestones": ["Backlog", "Doing", "Done"]
}
JSON
  }
  changed_lines() { diff "$tmp/cfg.orig" "$tmp/cfg.json" | grep -c '^[<>]'; }

  orig; cp "$tmp/cfg.json" "$tmp/cfg.orig"
  jq '.kitVersion = "0.9.0"' "$tmp/cfg.json" > "$tmp/m.json"
  t "one string key differs -> in-place" "$(json_write_minimal "$tmp/m.json" "$tmp/cfg.json")" "in-place"
  t "…one line removed, one added" "$(changed_lines)" "2"
  t "…the value is the merged one" "$(jq -c . "$tmp/cfg.json")" "$(jq -c '.kitVersion = "0.9.0"' "$tmp/cfg.orig")"
  t "…the merged temp file is consumed" "$([ -e "$tmp/m.json" ] && echo left || echo gone)" "gone"

  orig
  jq . "$tmp/cfg.json" > "$tmp/m.json"
  t "same value, different formatting -> unchanged" "$(json_write_minimal "$tmp/m.json" "$tmp/cfg.json")" "unchanged"
  t "…the file is byte-identical" "$(cmp -s "$tmp/cfg.orig" "$tmp/cfg.json" && echo same || echo differs)" "same"

  orig
  jq '.kitVersion = "0.9.0" | .knowledge = {dir: "knowledge"}' "$tmp/cfg.json" > "$tmp/m.json"
  t "a key is added -> rewritten" "$(json_write_minimal "$tmp/m.json" "$tmp/cfg.json")" "rewritten"
  t "…and holds the merged value" "$(jq -r '.knowledge.dir + " " + .kitVersion' "$tmp/cfg.json")" "knowledge 0.9.0"

  orig
  jq '.review.bots = ["one"]' "$tmp/cfg.json" > "$tmp/m.json"
  t "a nested value differs -> rewritten" "$(json_write_minimal "$tmp/m.json" "$tmp/cfg.json")" "rewritten"
  t "…and holds the merged value" "$(jq -c '.review.bots' "$tmp/cfg.json")" '["one"]'

  # A value with characters a careless substitution would mangle.
  orig
  jq '.note = "back\\slash $1 & \"q\" /"' "$tmp/cfg.json" > "$tmp/m.json"
  t "a string with quotes, backslash, \$1 and & -> in-place" "$(json_write_minimal "$tmp/m.json" "$tmp/cfg.json")" "in-place"
  t "…and it round-trips" "$(jq -r .note "$tmp/cfg.json")" 'back\slash $1 & "q" /'
  t "…one line removed, one added" "$(changed_lines)" "2"

  # The first textual match is not the top-level key: the in-place result fails its own check and
  # the write falls back to the whole document. The file never ends up holding a wrong value.
  printf '{\n  "inner": { "kitVersion": "nested" },\n  "kitVersion": "0.7.1"\n}\n' > "$tmp/cfg.json"
  jq '.kitVersion = "0.9.0"' "$tmp/cfg.json" > "$tmp/m.json"
  t "a nested key of the same name comes first -> rewritten, not mis-edited" "$(json_write_minimal "$tmp/m.json" "$tmp/cfg.json")" "rewritten"
  t "…both values are right" "$(jq -r '.inner.kitVersion + " " + .kitVersion' "$tmp/cfg.json")" "nested 0.9.0"

  rm -f "$tmp/cfg.json"
  printf '{"a":1}\n' > "$tmp/m.json"
  t "no file yet -> rewritten (created)" "$(json_write_minimal "$tmp/m.json" "$tmp/cfg.json")" "rewritten"
  t "…created with the merged value" "$(jq -c . "$tmp/cfg.json")" '{"a":1}'

  [ "$fail" = "0" ] && echo "ALL OK($sh_name)" || { echo "upgrade-report($sh_name): FAILURES"; exit 1; }
  exit 0
fi

command -v jq >/dev/null 2>&1 || { echo "upgrade-report-test: jq absent — skipping"; exit 0; }
rc=0
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || { echo "--- $sh --- (not installed, skipped)"; continue; }
  echo "--- $sh ---"
  UPGRADE_REPORT_TEST_INNER="$sh" "$sh" "$0" || rc=1
done
exit "$rc"
