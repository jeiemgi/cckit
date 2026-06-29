#!/usr/bin/env bash
# kit-export-training-test.sh — self-test for kit-export-training (#881). Runs under bash AND zsh.
# Proves the dataset-builder path is config-driven (NOT hardcoded): --builder > env > sibling discovery.
# Run:  bash scripts/kit-export-training-test.sh
PLUGIN_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

if [ -n "${KIT_XT_TEST_INNER:-}" ]; then
  set -u
  fail=0
  t() { if [ "$2" != "$3" ]; then echo "FAIL($KIT_XT_TEST_INNER): $1 -> got '[$2]' want '[$3]'"; fail=1; else echo "ok($KIT_XT_TEST_INNER): $1"; fi; }

  # Source the script: exposes functions, never runs main (verified by the source guard).
  . "$PLUGIN_DIR/scripts/kit-export-training.sh"
  t "resolver is defined" "$(command -v _kxt_resolve_builder >/dev/null && echo yes || echo no)" "yes"

  # 1) explicit --builder value wins over everything.
  KIT_DATASET_BUILDER="/env/build_dataset.py" \
    t "explicit --builder wins" "$(_kxt_resolve_builder /explicit/build_dataset.py)" "/explicit/build_dataset.py"

  # 2) KIT_DATASET_BUILDER env is used when no explicit value.
  t "env var used when no flag" "$(KIT_DATASET_BUILDER=/env/build_dataset.py _kxt_resolve_builder '')" "/env/build_dataset.py"

  # 3) sibling-repo discovery: a chat-datasets/build_dataset.py beside the git repo root is found,
  #    with NO hardcoded user path. Build a fake parent dir holding a repo + a sibling builder.
  parent="$(mktemp -d)"; trap 'rm -rf "$parent"' EXIT
  parent="$(cd "$parent" && pwd -P)"   # canonicalize (macOS /var -> /private/var) to match git rev-parse
  mkdir -p "$parent/myrepo" "$parent/chat-datasets"
  ( cd "$parent/myrepo" && git init -q )
  printf '#!/usr/bin/env python3\n' > "$parent/chat-datasets/build_dataset.py"
  got="$(cd "$parent/myrepo" && unset KIT_DATASET_BUILDER 2>/dev/null; _kxt_resolve_builder '')"
  t "sibling discovery off repo root" "$got" "$parent/chat-datasets/build_dataset.py"

  # 4) returns non-zero when nothing resolves (no flag, no env, no sibling).
  empty="$(mktemp -d)"; mkdir -p "$empty/solo"; ( cd "$empty/solo" && git init -q )
  ( cd "$empty/solo" && unset KIT_DATASET_BUILDER 2>/dev/null; _kxt_resolve_builder '' >/dev/null 2>&1 )
  t "fails closed when unresolved (rc 1)" "$?" "1"
  rm -rf "$empty"

  [ "$fail" -eq 0 ] && echo "ALL OK($KIT_XT_TEST_INNER)"
  exit "$fail"
fi

rc=0; ran=0
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || continue
  ran=$((ran+1)); echo "--- $sh ---"
  rcflag=""; [ "$sh" = "zsh" ] && rcflag="--no-rcs"
  KIT_XT_TEST_INNER="$sh" PATH="$PATH" PLUGIN_DIR="$PLUGIN_DIR" "$sh" $rcflag "$0" || rc=1
done
[ "$ran" -eq 0 ] && { echo "no shell"; exit 1; }
exit "$rc"
