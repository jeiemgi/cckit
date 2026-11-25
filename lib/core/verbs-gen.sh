#!/usr/bin/env bash
# verbs-gen.sh — write or check the CLI reference page's generated block (#555). The block sits
# between the `verbs:begin` and `verbs:end` comment markers of
# docs-site/src/content/docs/cli-reference.mdx and is produced by verbs_reference_md from
# lib/core/verbs.tsv, the one source for every verb.
#
#   lib/core/verbs-gen.sh           rewrite the block from the table
#   lib/core/verbs-gen.sh --check   rc 0 when the block matches the table, 1 (and a diff) when not
#   lib/core/verbs-gen.sh --root <dir>   act on another checkout
# errors: strict — set -e; a page without both markers exits 1
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
mode="write"
while [ $# -gt 0 ]; do
  case "$1" in
    --check) mode=check; shift ;;
    --root) ROOT="$(cd "${2:?--root needs a directory}" && pwd)"; shift 2 ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "verbs-gen: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
page="$ROOT/docs-site/src/content/docs/cli-reference.mdx"
VERBS_FILE="$ROOT/lib/core/verbs.tsv"; export VERBS_FILE
# shellcheck source=/dev/null
source "$ROOT/lib/core/verbs.sh"
grep -q '{/\* verbs:begin' "$page" && grep -q '{/\* verbs:end' "$page" \
  || { echo "verbs-gen: $page lacks the verbs:begin / verbs:end markers" >&2; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
verbs_reference_md > "$tmp/block"
awk -v blk="$tmp/block" '
  /\{\/\* verbs:begin/ { print; print ""; while ((getline l < blk) > 0) print l; print ""; skip = 1; next }
  /\{\/\* verbs:end/   { skip = 0 }
  !skip { print }' "$page" > "$tmp/page"

if [ "$mode" = check ]; then
  if cmp -s "$page" "$tmp/page"; then echo "ok verbs-gen: the CLI reference block matches lib/core/verbs.tsv"; exit 0; fi
  echo "verbs-gen: the CLI reference block drifted from lib/core/verbs.tsv (run: bash lib/core/verbs-gen.sh)" >&2
  diff "$page" "$tmp/page" >&2 || true
  exit 1
fi
cat "$tmp/page" > "$page"
echo "verbs-gen: wrote the generated block of $page"
