#!/usr/bin/env bash
# kit-operate.sh — the single operation machine (D10, #368).
#
# Every kit mutation (init, wire, promote, migrate, remove) is the SAME four-beat machine:
#   propose diff  ->  ask permission  ->  apply  ->  record in manifest
# Building it once means those five commands are configurations of one audited, idempotent,
# dry-runnable primitive — not five hand-rolled file-stompers. Honors KIT_DRY_RUN (preview only)
# and the conffiles rule from the manifest (never clobber user-modified files silently).
#
# Source it:  source scripts/lib/kit-operate.sh   (auto-sources kit-manifest.sh alongside)
# Env:
#   KIT_DRY_RUN=1     show what would happen, write nothing
#   KIT_ASSUME_YES=1  apply without the interactive confirm (CI / batch / Cowork)
#   KIT_NO_COLOR / NO_COLOR  plain output

_kit_op_dir="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=/dev/null
. "$_kit_op_dir/kit-manifest.sh"

_kit_op_say()  { printf '%s\n' "$*" >&2; }
_kit_op_dry()  { [ -n "${KIT_DRY_RUN:-}" ]; }

# _kit_op_confirm <prompt> -> rc 0 yes / 1 no
_kit_op_confirm() {
  [ -n "${KIT_ASSUME_YES:-}" ] && return 0
  [ -n "${KIT_DRY_RUN:-}" ] && return 1
  local reply; printf '%s [y/N] ' "$1" >&2
  IFS= read -r reply || return 1
  case "$reply" in y|Y|yes|YES) return 0;; *) return 1;; esac
}

# _kit_op_diff <src> <dest> — print a unified diff src->dest (best-effort, never fails the op)
_kit_op_diff() {
  local src="$1" dest="$2"
  if [ ! -f "$dest" ]; then _kit_op_say "  + create $dest"; return 0; fi
  if cmp -s "$src" "$dest"; then _kit_op_say "  = unchanged $dest"; return 0; fi
  _kit_op_say "  ~ update $dest"
  if command -v diff >/dev/null 2>&1; then diff -u "$dest" "$src" 2>/dev/null | sed 's/^/    /' >&2 || true; fi
}

# kit_op_write <src> <destrelpath> <tier> [op]
# Copy src -> dest with the four-beat machine. Respects conffiles: if dest is tracked and the user
# MODIFIED it, ask before overwriting even with KIT_ASSUME_YES.
# rc: 0 applied/created, 10 skipped (declined or dry-run), 1 error.
kit_op_write() {
  local src="$1" dest="$2" tier="${3:-A}" op="${4:-wire}"
  [ -f "$src" ] || { _kit_op_say "kit-operate: source missing: $src"; return 1; }

  # conffiles guard: tracked + user-modified => never silent overwrite
  local verdict; verdict="$(kit_manifest_verify "$dest" 2>/dev/null || true)"
  _kit_op_say "propose: $dest  (tier $tier, $op, current=$verdict)"
  _kit_op_diff "$src" "$dest"

  if cmp -s "$src" "$dest" 2>/dev/null; then
    # content already identical — just (re)record, no write needed (idempotent)
    _kit_op_dry || kit_manifest_record "$dest" "$tier" "$op" || return 1
    return 0
  fi

  if [ "$verdict" = "modified" ]; then
    if ! _kit_op_confirm "  $dest was edited by you — overwrite?"; then
      _kit_op_say "  skip (kept your version): $dest"; return 10
    fi
  elif ! _kit_op_confirm "  apply?"; then
    _kit_op_say "  skip: $dest"; return 10
  fi

  if _kit_op_dry; then _kit_op_say "  [dry-run] would write $dest"; return 10; fi
  mkdir -p "$(dirname "$dest")" || return 1
  cp -- "$src" "$dest" || return 1
  kit_manifest_record "$dest" "$tier" "$op" || return 1
  _kit_op_say "  applied: $dest"
}

# kit_op_write_content <destrelpath> <tier> <op>  (content on stdin)
# Same machine but the source is piped — for generated files (KIT.md, shims).
kit_op_write_content() {
  local dest="$1" tier="${2:-A}" op="${3:-wire}" tmp
  tmp="$(mktemp)" || return 1
  cat > "$tmp"
  kit_op_write "$tmp" "$dest" "$tier" "$op"; local rc=$?
  rm -f "$tmp"; return $rc
}

# kit_op_remove <destrelpath>
# Manifest-driven uninstall (D12 conffiles): intact->delete, modified->ask, missing->drop entry,
# untracked->refuse. rc: 0 removed/cleaned, 10 kept (declined/untracked), 1 error.
kit_op_remove() {
  local dest="$1" verdict; verdict="$(kit_manifest_verify "$dest")"
  case "$verdict" in
    untracked) _kit_op_say "refuse: $dest is not kit-managed — not touching it"; return 10;;
    missing)   _kit_op_say "clean: $dest already gone, dropping manifest entry"
               _kit_op_dry || kit_manifest_remove_entry "$dest"; return 0;;
    modified)  # Deleting a USER-EDITED file is NEVER silent — even under KIT_ASSUME_YES. Losing
               # the user's work to an automated run is exactly what conffiles (D12) prevents.
               if _kit_op_dry; then _kit_op_say "  [dry-run] would ASK before deleting edited $dest"; return 10; fi
               local _r=""; printf '  %s was edited by you — delete anyway? [y/N] ' "$dest" >&2
               IFS= read -r _r </dev/tty 2>/dev/null || IFS= read -r _r 2>/dev/null || _r=""
               case "$_r" in y|Y|yes|YES) ;; *) _kit_op_say "  kept (your edits): $dest"; return 10;; esac;;
    intact)    : ;;  # safe to remove
  esac
  if _kit_op_dry; then _kit_op_say "  [dry-run] would remove $dest"; return 10; fi
  rm -f -- "$dest" && kit_manifest_remove_entry "$dest" || return 1
  _kit_op_say "  removed: $dest"
}
