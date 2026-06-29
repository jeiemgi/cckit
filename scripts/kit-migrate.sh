#!/usr/bin/env bash
# kit-migrate.sh — reshuffle an OLD kit layout to the v2 one, idempotently, surviving /kit-update (#373).
#
# THE PROBLEM: early kits scaffolded skills as `task-*` (task-new/task-pr/...). v2 renamed them to
# `kit-task-*` (skillPrefix='kit-'). A project that initialized on the old layout still has the old
# dirs; a naive rename leaves three latent bugs:
#   1. /kit-update RESURRECTS the old `task-*` dirs ("add missing files") — the known incident.
#   2. The ownership manifest still points at the dead old paths -> remove can't leave clean.
#   3. CLAUDE.md / rules still say `/task-pr` -> the docs reference skills that no longer exist.
# kit-migrate fixes all three in one audited pass, and is a no-op on a project already on v2.
#
# WHAT IT DOES (per old->new pair in the migration map):
#   a. BACKUP the project's .claude/ once (timestamped) before the first change.
#   b. MOVE the file/dir content old->new (only if old exists and new doesn't — never clobber).
#   c. RE-KEY any manifest entry old->new (so update/remove track the v2 path).
#   d. REGISTER the rename in kit.config.json `upgrade.renamed{}` so /kit-update NEVER re-adds the
#      old path (this is the resurrection guard, #334).
#   e. CLAUDE.md / rules SURGERY: rewrite `/task-<verb>` references to `/kit-task-<verb>`.
# Idempotent: a second run finds the old paths already gone + already registered -> no-op.
# Honors KIT_DRY_RUN (preview, no writes) and KIT_ASSUME_YES (no confirm).
#
# Run:
#   scripts/kit-migrate.sh             # interactive
#   scripts/kit-migrate.sh --dry-run   # preview the reshuffle, write nothing
#   KIT_ASSUME_YES=1 scripts/kit-migrate.sh   # non-interactive (CI / batch)
# Requires: jq.

set -uo pipefail
_mig_dir="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=/dev/null
. "$_mig_dir/lib/kit-operate.sh"   # four-beat machine + kit-manifest.sh
# shellcheck source=/dev/null
. "$_mig_dir/lib/kit-cli.sh"       # kit_is_main

# The old->v2 migration map: one "OLD_RELPATH|NEW_RELPATH" per line. Data-driven so the set of
# renames is auditable + extensible without touching the engine. Today: the task-* -> kit-task-*
# skill rename (skillPrefix='kit-'), plus task-gc -> kit-gc.
_kit_migrate_map() {
  cat <<'MAP'
.claude/skills/task-new|.claude/skills/kit-task-new
.claude/skills/task-start|.claude/skills/kit-task-start
.claude/skills/task-pr|.claude/skills/kit-task-pr
.claude/skills/task-pr-merge|.claude/skills/kit-task-pr-merge
.claude/skills/task-pr-auto|.claude/skills/kit-task-pr-auto
.claude/skills/task-sync|.claude/skills/kit-task-sync
.claude/skills/task-close|.claude/skills/kit-task-close
.claude/skills/task-gc|.claude/skills/kit-gc
MAP
}

_kit_migrate_cfg() { printf '%s\n' ".claude/kit.config.json"; }

# Register OLD path in kit.config.json upgrade.renamed{} (-> NEW) so /kit-update skips re-adding it.
# Idempotent: writes only if the key is absent or points elsewhere. (#334 resurrection guard.)
_kit_migrate_register_rename() {
  local old="$1" new="$2" cfg cur tmp
  cfg="$(_kit_migrate_cfg)"
  [ -f "$cfg" ] || { _kit_op_say "  (no $cfg — skip rename registry for $old)"; return 0; }
  cur="$(jq -r --arg k "$old" '.upgrade.renamed[$k] // empty' "$cfg" 2>/dev/null || true)"
  [ "$cur" = "$new" ] && return 0   # already registered
  if _kit_op_dry; then _kit_op_say "  [dry-run] would register upgrade.renamed[$old]=$new in $cfg"; return 0; fi
  tmp="$(mktemp)" || return 1
  jq --arg k "$old" --arg v "$new" \
     '.upgrade = (.upgrade // {}) | .upgrade.renamed = (.upgrade.renamed // {}) | .upgrade.renamed[$k] = $v' \
     "$cfg" > "$tmp" && mv "$tmp" "$cfg" || { rm -f "$tmp"; return 1; }
  _kit_op_say "  registered upgrade.renamed[$old] -> $new"
}

# Re-key a manifest entry old->new, preserving tier/op (so update/remove track the v2 path).
_kit_migrate_rekey_manifest() {
  local old="$1" new="$2" mf entry tier op tmp
  mf="$(kit_manifest_path)"; [ -f "$mf" ] || return 0
  entry="$(jq -ec --arg p "$old" '.entries[$p] // empty' "$mf" 2>/dev/null || true)"
  [ -n "$entry" ] || return 0
  tier="$(printf '%s' "$entry" | jq -r '.tier // "A"')"
  op="$(printf '%s' "$entry" | jq -r '.op // "wire"')"
  if _kit_op_dry; then _kit_op_say "  [dry-run] would re-key manifest $old -> $new"; return 0; fi
  # record the new path at its (now moved) content, then drop the old entry
  kit_manifest_record "$new" "$tier" "$op" >/dev/null 2>&1 || true
  kit_manifest_remove_entry "$old" || true
}

_kit_migrate_backup_done=""
# Backup .claude/ once per run, before the first mutation. Skipped under dry-run.
_kit_migrate_backup() {
  [ -n "$_kit_migrate_backup_done" ] && return 0
  _kit_migrate_backup_done=1
  _kit_op_dry && { _kit_op_say "  [dry-run] would back up .claude/ before migrating"; return 0; }
  [ -d .claude ] || return 0
  local bk=".claude.bak.$(date -u +%Y%m%d%H%M%S 2>/dev/null || echo migrate)"
  cp -R .claude "$bk" 2>/dev/null && _kit_op_say "  backed up .claude/ -> $bk" || _kit_op_say "  (backup skipped — cp failed, continuing)"
}

# CLAUDE.md + rules surgery: rewrite /task-<verb> -> /kit-task-<verb>, task-gc -> kit-gc.
# Operates on CLAUDE.md and .claude/rules/*.md. Idempotent (already-migrated text has no /task-).
_kit_migrate_doc_surgery() {
  local f changed=0 tmp files=()
  [ -f CLAUDE.md ] && files+=(CLAUDE.md)
  if [ -d .claude/rules ]; then
    while IFS= read -r f; do [ -n "$f" ] && files+=("$f"); done < <(find .claude/rules -maxdepth 1 -type f -name '*.md' 2>/dev/null)
  fi
  for f in ${files[@]+"${files[@]}"}; do
    [ -f "$f" ] || continue
    # match /task-<verb> not already preceded by 'kit-' ; and the bare task-gc skill name.
    if grep -Eq '/(task-(new|start|pr|pr-merge|pr-auto|sync|close)|task-gc)\b' "$f" 2>/dev/null; then
      if _kit_op_dry; then _kit_op_say "  [dry-run] would rewrite /task-* -> /kit-task-* in $f"; changed=1; continue; fi
      tmp="$(mktemp)" || return 1
      sed -E 's#/task-(new|start|pr-merge|pr-auto|pr|sync|close)#/kit-task-\1#g; s#/task-gc#/kit-gc#g' "$f" > "$tmp" \
        && mv "$tmp" "$f" && { _kit_op_say "  rewrote skill refs in $f"; changed=1; } || rm -f "$tmp"
    fi
  done
  [ "$changed" -eq 0 ] && _kit_op_say "  (docs reference current skill names — no rewrite needed)"
  return 0
}

# kit_migrate_all — run the full reshuffle. Returns 0 (a project already on v2 is success / no-op).
kit_migrate_all() {
  command -v jq >/dev/null 2>&1 || { echo "kit-migrate: jq required" >&2; return 1; }

  # First pass: what WOULD move? (so we can show a plan + confirm before any write)
  local arr=() line old new pending=0
  while IFS= read -r line; do [ -n "$line" ] && arr+=("$line"); done < <(_kit_migrate_map)
  for line in ${arr[@]+"${arr[@]}"}; do
    old="${line%%|*}"; new="${line##*|}"
    [ -e "$old" ] && [ ! -e "$new" ] && pending=$((pending+1))
  done

  if [ "$pending" -eq 0 ]; then
    _kit_op_say "kit-migrate: layout already on v2 (no old task-* paths to move)."
    # Still ensure the renames are registered + docs are clean (idempotent backfill for partial runs).
    for line in ${arr[@]+"${arr[@]}"}; do
      old="${line%%|*}"; new="${line##*|}"
      [ ! -e "$old" ] && _kit_migrate_register_rename "$old" "$new"
    done
    _kit_migrate_doc_surgery
    return 0
  fi

  _kit_op_say "kit-migrate: $pending old-layout path(s) to reshuffle to v2:"
  for line in ${arr[@]+"${arr[@]}"}; do
    old="${line%%|*}"; new="${line##*|}"
    [ -e "$old" ] && [ ! -e "$new" ] && _kit_op_say "  ~ $old  ->  $new"
  done

  if [ -z "${KIT_ASSUME_YES:-}" ] && [ -z "${KIT_DRY_RUN:-}" ]; then
    printf 'kit-migrate: reshuffle %s path(s) (a .claude/ backup is taken first)? [y/N] ' "$pending" >&2
    local _c=""; IFS= read -r _c </dev/tty 2>/dev/null || IFS= read -r _c 2>/dev/null || _c=""
    case "$_c" in y|Y|yes|YES) ;; *) _kit_op_say "kit-migrate: aborted (nothing moved)."; return 0;; esac
  fi

  _kit_migrate_backup

  local moved=0
  for line in ${arr[@]+"${arr[@]}"}; do
    old="${line%%|*}"; new="${line##*|}"
    if [ -e "$old" ] && [ ! -e "$new" ]; then
      if _kit_op_dry; then
        _kit_op_say "  [dry-run] would move $old -> $new"
      else
        mkdir -p "$(dirname "$new")" && mv "$old" "$new" && { _kit_op_say "  moved $old -> $new"; moved=$((moved+1)); }
        # re-key the manifest for the moved file(s). For a dir, re-key each tracked child.
        if [ -d "$new" ]; then
          local child rel
          while IFS= read -r child; do
            rel="${child#./}"
            _kit_migrate_rekey_manifest "${old}/${rel#"$new/"}" "$rel" 2>/dev/null || true
          done < <(find "$new" -type f 2>/dev/null)
        else
          _kit_migrate_rekey_manifest "$old" "$new"
        fi
      fi
    fi
    # Register the rename either way (so update never resurrects $old) — idempotent.
    _kit_migrate_register_rename "$old" "$new"
  done

  _kit_migrate_doc_surgery
  _kit_op_say "kit-migrate: done ($moved moved). Old paths registered as renamed — /kit-update will not resurrect them."
}

# CLI (direct execution only)
if kit_is_main; then
  while [ $# -gt 0 ]; do case "$1" in
    --dry-run) export KIT_DRY_RUN=1; shift;;
    --yes|-y)  export KIT_ASSUME_YES=1; shift;;
    -h|--help) echo "usage: kit-migrate.sh [--dry-run] [--yes]   (env: KIT_ASSUME_YES, KIT_DRY_RUN)"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac; done
  kit_migrate_all
fi
