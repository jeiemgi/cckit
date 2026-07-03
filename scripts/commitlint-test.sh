#!/usr/bin/env bash
# commitlint-test.sh — the PR-title Conventional Commits gate (scripts/lib/commitlint.sh).
# Hermetic, no network. Discovered by scripts/test.sh, folded into scripts/check.sh + CI.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
# shellcheck source=/dev/null
. "$ROOT/scripts/lib/commitlint.sh"

ok()  { if commitlint_check "$1" >/dev/null 2>&1; then echo "ok:   accept '$1'"; else echo "FAIL: should ACCEPT '$1'"; fail=1; fi; }
bad() { if commitlint_check "$1" >/dev/null 2>&1; then echo "FAIL: should REJECT '$1'"; fail=1; else echo "ok:   reject '$1'"; fi; }

# --- valid subjects (every version-bump level + non-functional types) ---
ok "feat: add a thing"
ok "fix: correct a bug"
ok "feat(orchestrate): headless launch"
ok "fix(config): base feature work on develop"
ok "feat!: drop the old flag"
ok "feat(api)!: rename the export"
ok "perf: speed up the scan"
ok "refactor: extract a helper"
ok "revert: undo the change"
ok "docs: update releasing.mdx"
ok "chore: bump deps"
ok "chore(main): release 1.2.3"          # release-please's own Release PR title
ok "ci: pin the runner"
ok "build: adjust the bundle"
ok "style: reformat"
ok "test: add coverage"
ok "fix(scope-with-dash): ok"
ok "feat(docs-site): scoped slash allowed"

# --- invalid subjects ---
bad "add a thing"                          # no type
bad "Feat: capitalized type"               # type must be lowercase
bad "feat add a thing"                     # missing colon
bad "feat:no space after colon"            # missing space
bad "feat: "                               # empty description
bad "feat:"                                # empty description, no space
bad "wip: not a conventional type"         # unknown type
bad "feature: not the short form"          # unknown type
bad "feat(): empty scope"                  # scope cannot be empty
bad ""                                     # empty subject

# --- CLI form works and mirrors the function ---
if bash "$ROOT/scripts/lib/commitlint.sh" "feat: via cli" >/dev/null 2>&1; then
  echo "ok:   CLI accepts a valid subject"
else
  echo "FAIL: CLI should accept a valid subject"; fail=1
fi
if bash "$ROOT/scripts/lib/commitlint.sh" "nope" >/dev/null 2>&1; then
  echo "FAIL: CLI should reject an invalid subject"; fail=1
else
  echo "ok:   CLI rejects an invalid subject"
fi

[ "$fail" -eq 0 ] && echo "ALL OK (commitlint)" || echo "commitlint: FAILURES"
exit "$fail"
