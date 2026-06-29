#!/usr/bin/env bash
# kit-promote.sh — promote a project-local skill/agent to the workspace COMMONS so sibling
# projects can share it (#374). Born-local, shareable by ascent.
#
# MECHANICS (decided in the v2 plan, F6):
#   - The commons is `<workspace>/.claude/` (workspace root = nearest ancestor with kit.workspace.json).
#   - Promotion COPIES the file up to the commons (not symlink): Cowork ignores symlinks pointing
#     outside a plugin dir, and a copy works on every surface. Hash in the manifest detects drift.
#   - Writing ABOVE the current project ALWAYS asks permission (D10) — the commons is shared ground.
#   - The promoted copy is recorded in BOTH manifests (workspace + project) so kit-wire/remove and
#     duplicate-detection can reason about it. The project copy becomes a tracked mirror: editing it
#     locally is drift the kit will flag (edit at the workspace level instead).
#
# Run:   scripts/kit-promote.sh <relpath-under-.claude>          # e.g. skills/brand-voice/SKILL.md
#        scripts/kit-promote.sh --candidates <dir1> <dir2> ...   # list exact-dup files across projects
# Env:   KIT_ASSUME_YES (skip the above-project permission prompt), KIT_DRY_RUN.
# Requires: jq.

set -uo pipefail
_pr_dir="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=/dev/null
. "$_pr_dir/lib/kit-operate.sh"   # manifest + operate
# shellcheck source=/dev/null
. "$_pr_dir/lib/kit-cli.sh"       # kit_is_main, kit_say/die

# kit_workspace_root [startdir] -> path of nearest ancestor holding kit.workspace.json (empty if none)
kit_workspace_root() {
  local d; d="$(cd "${1:-$PWD}" 2>/dev/null && pwd)" || return 1
  while [ -n "$d" ]; do
    [ -f "$d/kit.workspace.json" ] && { printf '%s\n' "$d"; return 0; }
    [ "$d" = "/" ] && break
    d="$(dirname "$d")"
  done
  return 1
}

# kit_promote <relpath> — relpath is under the project's .claude/ (e.g. skills/foo/SKILL.md).
# Copies <proj>/.claude/<relpath> -> <ws>/.claude/<relpath>, records both sides.
kit_promote() {
  command -v jq >/dev/null 2>&1 || { kit_die "jq required"; }
  local rel="$1"
  [ -n "$rel" ] || { kit_die "usage: kit-promote.sh <relpath-under-.claude>"; }
  local proj_file=".claude/$rel"
  [ -f "$proj_file" ] || { kit_die "not found: $proj_file"; }

  local ws; ws="$(kit_workspace_root)" || { kit_die "no workspace root (kit.workspace.json) found above $PWD — promotion needs a workspace."; }
  local proj; proj="$(pwd)"
  if [ "$ws" = "$proj" ]; then kit_die "already at the workspace root — nothing to promote up."; fi

  local dest="$ws/.claude/$rel"
  kit_say "promote: $proj_file"
  kit_say "    ->   $dest   (workspace commons)"

  # Writing ABOVE the project always asks (D10), unless KIT_ASSUME_YES.
  if [ -z "${KIT_ASSUME_YES:-}" ] && [ -z "${KIT_DRY_RUN:-}" ]; then
    printf 'Write to the workspace commons (above this project)? [y/N] ' >&2
    local c=""; IFS= read -r c </dev/tty 2>/dev/null || IFS= read -r c 2>/dev/null || c=""
    case "$c" in y|Y|yes|YES) ;; *) kit_say "aborted."; return 0;; esac
  fi
  if [ -n "${KIT_DRY_RUN:-}" ]; then kit_say "  [dry-run] would copy to commons + record both manifests"; return 10; fi

  mkdir -p "$(dirname "$dest")"
  cp -- "$proj_file" "$dest"
  # record in the WORKSPACE manifest (commons owner)
  ( cd "$ws" && KIT_MANIFEST=".claude/kit.manifest.json" kit_manifest_record ".claude/$rel" A promote >/dev/null 2>&1 ) || true
  # record the project copy as a promoted mirror (so drift can be detected; edit upstream instead)
  kit_manifest_record "$proj_file" A promote-mirror >/dev/null 2>&1 || true
  kit_say "  promoted. Edit it at the workspace level; the project copy is a tracked mirror."
}

# kit_promote_candidates <dir>... — find files that are byte-identical across 2+ given project
# .claude/ trees (exact-dup = a promotion candidate). Prints "<count>\t<relpath>" for dups.
kit_promote_candidates() {
  command -v jq >/dev/null 2>&1 || { kit_die "jq required"; }
  [ "$#" -ge 2 ] || { kit_die "usage: --candidates <dir1> <dir2> [..]"; }
  local d f rel h
  # emit "hash<TAB>relpath" for every skill/agent file under each dir's .claude/{skills,agents}
  { for d in "$@"; do
      [ -d "$d/.claude" ] || continue
      while IFS= read -r f; do
        [ -f "$f" ] || continue
        rel="${f#"$d"/.claude/}"
        h="$(kit_manifest_hash "$f")"
        printf '%s\t%s\n' "$h" "$rel"
      done <<EOF
$(find "$d/.claude/skills" "$d/.claude/agents" -type f 2>/dev/null)
EOF
    done
  } | LC_ALL=C sort | awk -F'\t' '
      { if ($1==ph) { cnt++ } else { if (cnt>1) print cnt"\t"prel; ph=$1; prel=$2; cnt=1 } }
      END { if (cnt>1) print cnt"\t"prel }'
}

# CLI
if kit_is_main; then
  case "${1:-}" in
    --candidates) shift; kit_promote_candidates "$@";;
    -h|--help) echo "usage: kit-promote.sh <relpath-under-.claude> | --candidates <dir>...";;
    "") kit_die "usage: kit-promote.sh <relpath-under-.claude> | --candidates <dir>...";;
    *) kit_promote "$1";;
  esac
fi
