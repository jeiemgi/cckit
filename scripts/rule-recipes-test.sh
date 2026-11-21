#!/usr/bin/env bash
# rule-recipes-test.sh — the shell recipes printed in the shipped rules run where the rule says.
#
# A rule is prose, but a fenced command in it is followed verbatim by an agent. Two recipes were
# wrong in the place they are read (PR 437 review):
#   1. shared-checkout.md — the "am I in the primary checkout" test compared `git rev-parse
#      --git-dir` with `--git-common-dir` as strings. From a subdirectory of the primary checkout
#      they print `/abs/.git` and `../.git`, so the test printed nothing there.
#   2. gate-and-review.md — the evidence recipe sourced pr-evidence.sh from a directory that, in a
#      scaffolded project, is the project's own scripts/lib, where `cckit init` never copied it.
#
# The recipe lines are READ OUT OF the rule files and executed, so the rule and the test cannot
# drift apart. Network-free. Run:  bash scripts/rule-recipes-test.sh

set -uo pipefail
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

fail=0
t() {  # t <label> <got> <want>
  if [ "$2" != "$3" ]; then echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; else echo "ok: $1"; fi
}

command -v git >/dev/null 2>&1 || { echo "SKIP: git not available"; exit 0; }

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

# ── 1. shared-checkout.md: the primary-checkout test ────────────────────────────────────────────
# The recipe is the `[ … ] && echo "primary checkout"` statement in the rule's first bash block; a
# trailing backslash continues it onto the next line.
primary_recipe() {  # <rule file> → the statement, continuation lines joined
  awk '
    /^\[ "\$\(git rev-parse/ { on = 1 }
    on { print; if ($0 !~ /\\$/) exit }
  ' "$1"
}

repo="$work/repo"
mkdir -p "$repo/deep/er"
git -C "$repo" init -q
git -C "$repo" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m seed
git -C "$repo" worktree add -q "$work/linked" -b linked >/dev/null 2>&1
mkdir -p "$work/linked/deep"

for rule in templates/rules/shared-checkout.md .claude/rules/shared-checkout.md; do
  recipe="$(primary_recipe "$ROOT/$rule")"
  t "$rule: recipe found"                      "$([ -n "$recipe" ] && echo yes || echo no)" "yes"
  [ -n "$recipe" ] || continue
  t "$rule: primary, top level"                "$(cd "$repo"          && eval "$recipe" 2>&1)" "primary checkout"
  t "$rule: primary, subdirectory"             "$(cd "$repo/deep"     && eval "$recipe" 2>&1)" "primary checkout"
  t "$rule: primary, nested subdirectory"      "$(cd "$repo/deep/er"  && eval "$recipe" 2>&1)" "primary checkout"
  t "$rule: linked worktree, top level"        "$(cd "$work/linked"      && eval "$recipe" 2>&1)" ""
  t "$rule: linked worktree, subdirectory"     "$(cd "$work/linked/deep" && eval "$recipe" 2>&1)" ""
done

# ── 2. gate-and-review.md: the evidence recipe in a scaffolded project ──────────────────────────
if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not available (scaffold half)"
else
  proj="$work/proj"
  mkdir -p "$proj/.claude"
  git -C "$proj" init -q
  cat > "$proj/.claude/kit.config.json" <<JSON
{
  "kitVersion": "0.0.1",
  "profile": "software",
  "project": { "name": "RecipeTest", "slug": "recipe-test" },
  "github": { "repo": "example/recipe-test", "owner": "example", "projectsV2": false }
}
JSON
  # The --upgrade path is the network-free scaffold (no doctor, no gh) init-upgrade-test.sh uses.
  CLAUDE_PLUGIN_ROOT="$ROOT" bash "$ROOT/scripts/init.sh" --upgrade --target "$proj" --force >/dev/null 2>&1 \
    || { echo "FAIL: scaffold exited non-zero"; exit 1; }

  rule="$proj/.claude/rules/gate-and-review.md"
  t "scaffold installed gate-and-review.md"    "$([ -f "$rule" ] && echo yes || echo no)" "yes"

  src_line="$(grep -E '^source .*pr-evidence\.sh' "$rule" 2>/dev/null | sed -n 1p | sed 's/[[:space:]]*#.*$//')"
  t "rule carries a source line"               "$([ -n "$src_line" ] && echo yes || echo no)" "yes"
  t "source line has no placeholder"           "$(printf '%s' "$src_line" | grep -c '<')" "0"
  t "the rule's source line defines pr_attach_evidence in the project" \
    "$(cd "$proj" && bash -c "$src_line 2>/dev/null; type pr_attach_evidence >/dev/null 2>&1 && echo defined || echo undefined")" \
    "defined"

  # The row above the recipe says `cckit lib` lists the helper: that is the directory kit_lib_dir
  # resolves for this project, so the helper has to be in it.
  libdir="$(cd "$proj" && env -u KIT_LIB_DIR bash -c '. "$1/scripts/lib/kit-lib.sh"; kit_lib_dir "$2"' _ "$ROOT" "$proj")"
  t "kit_lib_dir resolves the project's own library" "$libdir" "$proj/scripts/lib"
  t "that library holds pr-evidence.sh"        "$([ -f "$libdir/pr-evidence.sh" ] && echo yes || echo no)" "yes"

  # The docs page repeats the recipe; it must be the same line the rule ships.
  doc_line="$(grep -E '^source .*pr-evidence\.sh' "$ROOT/docs-site/src/content/docs/rules.mdx" | sed -n 1p | sed 's/[[:space:]]*#.*$//')"
  t "docs-site rules.mdx repeats the rule's source line" "$doc_line" "$src_line"
fi

if [ "$fail" -eq 0 ]; then echo "rule-recipes-test: OK"; else echo "rule-recipes-test: FAILED"; fi
exit "$fail"
