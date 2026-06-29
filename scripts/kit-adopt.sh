#!/usr/bin/env bash
# kit-adopt.sh — adopt kit-shaped files a project ALREADY has into the ownership manifest (#373).
#
# THE MOMENT: a project imported the kit by hand (copied a .claude/ from another repo, ran an old
# init, or a teammate pasted skills/rules in) — the files are PRESENT but the manifest doesn't know
# them, so update/remove can't manage them safely (kit_manifest_verify says `untracked` -> "never
# touch"). kit-adopt walks the kit-shaped paths that exist on disk, shows what it would adopt
# (dry-run diff), and — on confirm — RECORDS each into the manifest at its current hash. It writes
# NO file content; it only takes ownership of what's already there. After adopting, /kit-update can
# refresh them and kit-remove can leave clean.
#
# It is the read-only counterpart to kit-wire: wire WRITES the kit's own files; adopt CLAIMS files
# the project brought. It never claims a file that is not kit-shaped (your knowledge/, plans/,
# drafts/, app code are off-limits) and never overwrites — adoption is hash-recording only.
#
# Run:
#   scripts/kit-adopt.sh             # interactive: list candidates, confirm, record
#   scripts/kit-adopt.sh --dry-run   # preview only
#   scripts/kit-adopt.sh --check     # report unmanaged kit-shaped files, write nothing (rc 1 if any)
#   KIT_ASSUME_YES=1 scripts/kit-adopt.sh   # non-interactive (init/CI/Cowork)
# Requires: jq + a sha256 tool.

set -uo pipefail
_adopt_dir="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=/dev/null
. "$_adopt_dir/lib/kit-operate.sh"   # four-beat machine + kit-manifest.sh
# shellcheck source=/dev/null
. "$_adopt_dir/lib/kit-cli.sh"       # kit_is_main

# Tier-classify a kit-shaped path. Statusline shim + settings + hooks are CLI-only (tier B); the
# portable skills/rules/agents/commands are tier A (work in Cowork/claude.ai too). Mirrors kit-wire.
_kit_adopt_tier() {
  case "$1" in
    .claude/statusline.sh|.claude/settings.json|.claude/hooks/*|.claude/lib/*) printf 'B' ;;
    *) printf 'A' ;;
  esac
}

# Emit the set of kit-shaped paths that EXIST under the project but are NOT yet in the manifest.
# "kit-shaped" = the directories the kit owns (skills/rules/agents/commands/hooks/lib) + the two
# wired singletons. Never the user's content trees (knowledge/, plans/, drafts/, apps/, src/).
# One relpath per line.
kit_adopt_candidates() {
  local p verdict
  # Files under the kit-owned .claude subtrees.
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    p="${p#./}"
    verdict="$(kit_manifest_verify "$p" 2>/dev/null || true)"
    [ "$verdict" = "untracked" ] && printf '%s\n' "$p"
  done < <(
    find .claude/skills .claude/rules .claude/agents .claude/commands \
         .claude/hooks .claude/lib -type f 2>/dev/null
  )
  # The two wired singletons, if present.
  for p in .claude/statusline.sh .claude/settings.json; do
    [ -f "$p" ] || continue
    verdict="$(kit_manifest_verify "$p" 2>/dev/null || true)"
    [ "$verdict" = "untracked" ] && printf '%s\n' "$p"
  done
}

# kit_adopt_all — record every unmanaged kit-shaped file into the manifest at its current hash.
# Honors KIT_DRY_RUN (report only) and KIT_ASSUME_YES (skip the confirm). Returns 0 always (a clean
# project with nothing to adopt is success).
kit_adopt_all() {
  command -v jq >/dev/null 2>&1 || { echo "kit-adopt: jq required" >&2; return 1; }

  # Collect candidates into an array first (a per-file confirm's read must not eat the loop's stdin).
  local arr=() line
  while IFS= read -r line; do [ -n "$line" ] && arr+=("$line"); done < <(kit_adopt_candidates)

  local n="${#arr[@]}"
  if [ "$n" -eq 0 ]; then _kit_op_say "kit-adopt: nothing to adopt — every kit-shaped file is already tracked (or none present)."; return 0; fi

  _kit_op_say "kit-adopt: $n unmanaged kit-shaped file(s) found:"
  local p; for p in ${arr[@]+"${arr[@]}"}; do _kit_op_say "  + adopt $p ($(_kit_adopt_tier "$p"))"; done

  if _kit_op_dry; then _kit_op_say "  [dry-run] would record $n file(s) into the manifest"; return 0; fi

  if [ -z "${KIT_ASSUME_YES:-}" ]; then
    printf 'kit-adopt: take ownership of these %s file(s) in the manifest? [y/N] ' "$n" >&2
    local _c=""; IFS= read -r _c </dev/tty 2>/dev/null || IFS= read -r _c 2>/dev/null || _c=""
    case "$_c" in y|Y|yes|YES) ;; *) _kit_op_say "kit-adopt: aborted (nothing recorded)."; return 0;; esac
  fi

  kit_manifest_init || return 1
  local adopted=0
  for p in ${arr[@]+"${arr[@]}"}; do
    kit_manifest_record "$p" "$(_kit_adopt_tier "$p")" adopt >/dev/null && {
      adopted=$((adopted+1)); _kit_op_say "  adopted: $p"
    }
  done
  _kit_op_say "kit-adopt: $adopted file(s) now manifest-managed (update/remove can handle them safely)."
}

# --check: report unmanaged kit-shaped files, write nothing, rc 1 if any exist (SessionStart nudge).
kit_adopt_check() {
  local arr=() line
  while IFS= read -r line; do [ -n "$line" ] && arr+=("$line"); done < <(kit_adopt_candidates)
  local n="${#arr[@]}"
  [ "$n" -eq 0 ] && return 0
  _kit_op_say "kit-adopt --check: $n kit-shaped file(s) present but unmanaged — run 'kit-adopt' to take ownership:"
  local p; for p in ${arr[@]+"${arr[@]}"}; do _kit_op_say "  ? $p"; done
  return 1
}

# CLI (direct execution only)
if kit_is_main; then
  _mode=run
  while [ $# -gt 0 ]; do case "$1" in
    --dry-run) export KIT_DRY_RUN=1; shift;;
    --yes|-y)  export KIT_ASSUME_YES=1; shift;;
    --check)   _mode=check; shift;;
    -h|--help) echo "usage: kit-adopt.sh [--check] [--dry-run] [--yes]   (env: KIT_ASSUME_YES, KIT_DRY_RUN)"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac; done
  case "$_mode" in
    check) kit_adopt_check;;
    *)     kit_adopt_all;;
  esac
fi
