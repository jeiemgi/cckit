#!/usr/bin/env bash
# kit-remove.sh — uninstall the kit from a project, by MANIFEST, never by guesswork (#373).
#
# "You can leave clean" is the trust feature: removal walks the F0 ownership manifest in reverse
# and deletes only what the kit installed, applying the conffiles rule (D12):
#   intact    -> delete            (kit wrote it, user never touched it)
#   modified  -> ASK               (user edited it; default keep)
#   missing   -> just drop the entry
#   untracked -> never touched (can't happen via the manifest, but kit_op_remove refuses anyway)
# It NEVER deletes knowledge/, plans/, drafts/, the user's CLAUDE.md, or anything not in the
# manifest. Honors KIT_DRY_RUN; KIT_ASSUME_YES applies non-interactively (still asks on modified).
#
# Run:   scripts/kit-remove.sh            # interactive
#        scripts/kit-remove.sh --dry-run  # preview only
#        scripts/kit-remove.sh --yes      # non-interactive (modified files still prompt)
# Requires: jq.

set -uo pipefail
_rm_dir="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=/dev/null
. "$_rm_dir/lib/kit-operate.sh"   # brings kit-manifest.sh too
# shellcheck source=/dev/null
. "$_rm_dir/lib/kit-cli.sh"       # kit_is_main

# kit_remove_all — remove every manifest entry (reverse order so nested files go before dirs),
# then drop the manifest + prune now-empty .claude/kit dirs. Returns count kept (modified/declined).
kit_remove_all() {
  command -v jq >/dev/null 2>&1 || { echo "kit-remove: jq required" >&2; return 1; }
  local mf; mf="$(kit_manifest_path)"
  if [ ! -f "$mf" ]; then echo "kit-remove: no manifest ($mf) — nothing kit-managed here." >&2; return 0; fi

  # snapshot the tracked paths, reverse-sorted (longest/deepest first)
  local paths; paths="$(kit_manifest_list | LC_ALL=C sort -r)"
  if [ -z "$paths" ]; then echo "kit-remove: manifest is empty." >&2; rm -f "$mf"; return 0; fi

  # One top-level confirm for the whole uninstall (skipped under --yes / --dry-run). Per-file the
  # machine still protects user-modified files individually.
  local n; n="$(printf '%s\n' "$paths" | grep -c .)"
  if [ -z "${KIT_ASSUME_YES:-}" ] && [ -z "${KIT_DRY_RUN:-}" ]; then
    printf 'kit-remove: about to remove %s kit-managed file(s). Continue? [y/N] ' "$n" >&2
    local _c=""; IFS= read -r _c </dev/tty 2>/dev/null || IFS= read -r _c 2>/dev/null || _c=""
    case "$_c" in y|Y|yes|YES) ;; *) echo "kit-remove: aborted." >&2; return 0;; esac
  fi

  # Collect into an array FIRST, then iterate — so a per-file prompt's `read` inside the loop
  # can't steal the next path off the loop's stdin (classic while-read pitfall).
  local arr=() line
  while IFS= read -r line; do [ -n "$line" ] && arr+=("$line"); done <<EOF
$paths
EOF
  local total=0 removed=0 kept=0 p rc
  for p in ${arr[@]+"${arr[@]}"}; do
    total=$((total+1))
    kit_op_remove "$p"; rc=$?
    if [ "$rc" -eq 0 ]; then removed=$((removed+1)); else kept=$((kept+1)); fi
  done

  _kit_op_say "kit-remove: $removed removed, $kept kept (modified/declined), of $total tracked."
  # If every entry is gone, remove the (now-empty) manifest too.
  if [ -z "$(kit_manifest_list)" ]; then
    if _kit_op_dry; then _kit_op_say "  [dry-run] would delete empty manifest $mf"
    else rm -f "$mf"; _kit_op_say "  deleted empty manifest $mf"; fi
  else
    _kit_op_say "  manifest kept ($(kit_manifest_list | grep -c . ) entr(y/ies) remain — modified files you chose to keep)."
  fi
  # Remove any kit-managed cron entries for this project (fail-soft — missing crontab is fine).
  local rt_script; rt_script="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)/kit-routines.sh"
  if [ -f "$rt_script" ] && command -v crontab >/dev/null 2>&1; then
    bash "$rt_script" remove-all || true
  fi
  return 0
}

# CLI (direct execution only; zsh-safe guard)
# CLI (direct execution only)
if kit_is_main; then
  while [ $# -gt 0 ]; do case "$1" in
    --dry-run) export KIT_DRY_RUN=1; shift;;
    --yes|-y)  export KIT_ASSUME_YES=1; shift;;
    -h|--help) echo "usage: kit-remove.sh [--dry-run] [--yes]"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac; done
  kit_remove_all
fi
