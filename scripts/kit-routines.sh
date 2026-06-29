#!/usr/bin/env bash
# kit-routines.sh — suggested-routines cron catalogue: accept / remove / list / verify (#377).
#
# THE PHILOSOPHY: the kit SUGGESTS routines; the user accepts; nothing is created without opt-in.
# Accepted routines are stored in kit.config.json (.routines[]) and wired as OS cron jobs
# (crontab entries) scoped to the project directory. Each entry is tagged with the kit's sentinel
# comment so it can be identified and removed cleanly. The script NEVER auto-accepts anything.
#
# Operations:
#   kit-routines.sh list                    # show the catalogue with status (accepted / available)
#   kit-routines.sh accept <id> [--dir D]   # suggest -> add cron + record in kit.config.json
#   kit-routines.sh remove <id> [--dir D]   # remove cron + clear from kit.config.json
#   kit-routines.sh verify  [--dir D]       # check: config routines have matching cron entries
#   kit-routines.sh remove-all [--dir D]    # remove every kit-managed cron for this project (used by kit-remove)
#   KIT_DRY_RUN=1 kit-routines.sh ...       # preview any write op, write nothing
#   KIT_ASSUME_YES=1 kit-routines.sh ...    # non-interactive (CI / batch)
#
# Cron sentinel format — one line per routine:
#   # kit-managed:<project_slug>:<routine_id> <cron_expr> <command>
# This makes grep-based remove exact and never matches unrelated crontab lines.
#
# Requires: jq (catalogue parse + config patch), crontab (OS-level cron).

set -uo pipefail
_rt_dir="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=/dev/null
. "$_rt_dir/lib/kit-cli.sh"    # kit_is_main, kit_say, kit_warn, kit_die

# Plugin root — prefer CLAUDE_PLUGIN_ROOT, fall back to two levels up.
_kit_rt_plugin_root() {
  if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; return 0; fi
  ( CDPATH='' cd -- "$_rt_dir/.." && pwd )
}

_kit_rt_catalogue() {
  local f; f="$(_kit_rt_plugin_root)/routines/catalogue.json"
  [ -f "$f" ] || kit_die "routines catalogue not found: $f"
  cat "$f"
}

_kit_rt_dry()    { [ -n "${KIT_DRY_RUN:-}" ]; }
_kit_rt_yes()    { [ -n "${KIT_ASSUME_YES:-}" ]; }
_kit_rt_say()    { printf '%s\n' "$*" >&2; }

# ── project-slug helper ─────────────────────────────────────────────────────
# Derive a stable slug for cron sentinel tagging: use kit.config.json project.slug,
# fall back to the current directory name.
_kit_rt_slug() {
  local dir="${1:-$PWD}" slug
  slug="$(jq -r '.project.slug // empty' "$dir/.claude/kit.config.json" 2>/dev/null || true)"
  [ -n "$slug" ] && { printf '%s\n' "$slug"; return 0; }
  basename "$dir"
}

# ── catalogue helpers ────────────────────────────────────────────────────────
# kit_routines_get_by_id <id> -> JSON object or empty
kit_routines_get_by_id() {
  _kit_rt_catalogue | jq --arg id "$1" '.routines[] | select(.id==$id)'
}

# kit_routines_accepted <dir> -> space-separated list of accepted routine ids from kit.config.json
kit_routines_accepted() {
  local dir="${1:-$PWD}" cfg
  cfg="$dir/.claude/kit.config.json"
  [ -f "$cfg" ] || { printf ''; return 0; }
  jq -r '(.routines // [])[]' "$cfg" 2>/dev/null || true
}

# ── crontab helpers ──────────────────────────────────────────────────────────
# Sentinel comment identifies a kit-managed line: "# kit-managed:<slug>:<id>"
_kit_rt_sentinel() { printf '# kit-managed:%s:%s' "$1" "$2"; }

# _kit_rt_cron_line <sentinel> <cron_expr> <command_expanded> -> the full crontab line pair
_kit_rt_cron_line() {
  local sentinel="$1" expr="$2" cmd="$3"
  printf '%s\n%s %s\n' "$sentinel" "$expr" "$cmd"
}

# _kit_rt_expand_command <command_template> <scripts_dir> -> expanded command string
_kit_rt_expand_command() {
  local tmpl="$1" scripts="$2"
  printf '%s' "$tmpl" | sed "s|\${KIT_SCRIPTS}|$scripts|g"
}

# kit_routines_cron_has <sentinel> -> rc 0 if present in crontab
kit_routines_cron_has() {
  local sentinel="$1"
  crontab -l 2>/dev/null | grep -qF "$sentinel"
}

# kit_routines_cron_add <sentinel> <cron_line_pair>
# Appends the two-line pair (sentinel + cron) to the crontab if not already present.
kit_routines_cron_add() {
  local sentinel="$1" pair="$2" tmp
  if kit_routines_cron_has "$sentinel"; then
    _kit_rt_say "  = cron already present ($sentinel)"; return 0
  fi
  if _kit_rt_dry; then
    _kit_rt_say "  [dry-run] would add cron: $sentinel"; return 0
  fi
  tmp="$(mktemp)"
  { crontab -l 2>/dev/null; printf '\n%s\n' "$pair"; } > "$tmp" || { rm -f "$tmp"; return 1; }
  crontab "$tmp"; local rc=$?; rm -f "$tmp"
  [ "$rc" -eq 0 ] && _kit_rt_say "  + cron added: $sentinel" || { _kit_rt_say "  error: crontab write failed"; return 1; }
}

# kit_routines_cron_remove <sentinel>
# Removes every line whose PRECEDING line is the sentinel comment (the comment + cron line pair).
kit_routines_cron_remove() {
  local sentinel="$1" tmp
  if ! kit_routines_cron_has "$sentinel"; then
    _kit_rt_say "  = cron not found (already removed): $sentinel"; return 0
  fi
  if _kit_rt_dry; then
    _kit_rt_say "  [dry-run] would remove cron: $sentinel"; return 0
  fi
  tmp="$(mktemp)"
  # Strip the sentinel line AND the following non-empty cron line.
  crontab -l 2>/dev/null | awk -v s="$sentinel" '
    /^[[:space:]]*$/ { print; next }
    $0 == s { skip=1; next }
    skip { skip=0; next }
    { print }
  ' > "$tmp" || { rm -f "$tmp"; return 1; }
  crontab "$tmp"; local rc=$?; rm -f "$tmp"
  [ "$rc" -eq 0 ] && _kit_rt_say "  - cron removed: $sentinel" || { _kit_rt_say "  error: crontab write failed"; return 1; }
}

# ── config helpers ───────────────────────────────────────────────────────────
# kit_routines_config_add <id> <dir>
# Adds the routine id to kit.config.json .routines[] (idempotent).
kit_routines_config_add() {
  local id="$1" dir="${2:-$PWD}" cfg tmp
  cfg="$dir/.claude/kit.config.json"
  _kit_rt_dry && { _kit_rt_say "  [dry-run] would add '$id' to $cfg .routines[]"; return 0; }
  [ -f "$cfg" ] || printf '{}\n' > "$cfg"
  tmp="$(mktemp)"
  jq --arg id "$id" '.routines = ((.routines // []) + [$id] | unique)' "$cfg" > "$tmp" \
    && mv "$tmp" "$cfg" || { rm -f "$tmp"; return 1; }
  _kit_rt_say "  + recorded '$id' in $cfg"
}

# kit_routines_config_remove <id> <dir>
kit_routines_config_remove() {
  local id="$1" dir="${2:-$PWD}" cfg tmp
  cfg="$dir/.claude/kit.config.json"
  [ -f "$cfg" ] || return 0
  _kit_rt_dry && { _kit_rt_say "  [dry-run] would remove '$id' from $cfg .routines[]"; return 0; }
  tmp="$(mktemp)"
  jq --arg id "$id" '.routines = ((.routines // []) | map(select(. != $id)))' "$cfg" > "$tmp" \
    && mv "$tmp" "$cfg" || { rm -f "$tmp"; return 1; }
  _kit_rt_say "  - removed '$id' from $cfg"
}

# ── public operations ────────────────────────────────────────────────────────

# kit_routines_list [dir] — print the catalogue table with acceptance status.
kit_routines_list() {
  local dir="${1:-$PWD}"
  command -v jq >/dev/null 2>&1 || kit_die "jq required"
  local cat accepted
  cat="$(_kit_rt_catalogue)"
  accepted="$(kit_routines_accepted "$dir")"

  printf '%-22s  %-8s  %-8s  %-9s  %s\n' "ID" "CADENCE" "STATUS" "COST" "DESCRIPTION" >&2
  printf '%s\n' "-----------------------------------------------------------------------" >&2

  local n; n="$(printf '%s' "$cat" | jq '.routines | length')"
  local i=0
  while [ "$i" -lt "$n" ]; do
    local id cad cost desc status
    id="$(printf '%s' "$cat"   | jq -r ".routines[$i].id")"
    cad="$(printf '%s' "$cat"  | jq -r ".routines[$i].cadence")"
    cost="$(printf '%s' "$cat" | jq -r ".routines[$i].cost")"
    desc="$(printf '%s' "$cat" | jq -r ".routines[$i].description" | cut -c1-50)"
    if printf '%s\n' "$accepted" | grep -qx "$id" 2>/dev/null; then
      status="accepted"
    else
      status="available"
    fi
    printf '%-22s  %-8s  %-8s  %-9s  %s\n' "$id" "$cad" "$status" "$cost" "$desc" >&2
    i=$((i+1))
  done
}

# kit_routines_accept <id> [dir]
# Opt-in: look up the routine in the catalogue, add cron entry, record in config.
kit_routines_accept() {
  local id="$1" dir="${2:-$PWD}"
  command -v jq >/dev/null 2>&1 || kit_die "jq required"
  command -v crontab >/dev/null 2>&1 || kit_die "crontab required"

  dir="$(cd "$dir" 2>/dev/null && pwd)" || kit_die "no such dir: $dir"

  local entry; entry="$(kit_routines_get_by_id "$id")"
  [ -n "$entry" ] || kit_die "unknown routine '$id' (run: kit-routines.sh list)"

  local scripts; scripts="$(cd "$_rt_dir" && pwd)"
  local cron_expr cmd_tmpl cmd_expanded sentinel pair slug
  cron_expr="$(printf '%s' "$entry" | jq -r '.cron')"
  cmd_tmpl="$(printf '%s' "$entry"  | jq -r '.command')"
  cmd_expanded="$(_kit_rt_expand_command "$cmd_tmpl" "$scripts")"
  slug="$(_kit_rt_slug "$dir")"
  sentinel="$(_kit_rt_sentinel "$slug" "$id")"
  pair="$(_kit_rt_cron_line "$sentinel" "$cron_expr" "$cmd_expanded")"

  # One confirm unless non-interactive.
  if ! _kit_rt_dry && ! _kit_rt_yes; then
    local name; name="$(printf '%s' "$entry" | jq -r '.name')"
    printf 'Accept routine "%s" (%s, %s)? [y/N] ' "$name" "$id" "$cron_expr" >&2
    local reply=""; IFS= read -r reply || true
    case "$reply" in y|Y|yes|YES) ;; *) _kit_rt_say "  skipped."; return 0;; esac
  fi

  kit_routines_cron_add "$sentinel" "$pair" || return 1
  kit_routines_config_add "$id" "$dir" || return 1
  _kit_rt_say "routine '$id' accepted."
}

# kit_routines_remove <id> [dir]
kit_routines_remove() {
  local id="$1" dir="${2:-$PWD}"
  command -v jq >/dev/null 2>&1 || kit_die "jq required"
  command -v crontab >/dev/null 2>&1 || kit_die "crontab required"

  dir="$(cd "$dir" 2>/dev/null && pwd)" || kit_die "no such dir: $dir"
  local slug; slug="$(_kit_rt_slug "$dir")"
  local sentinel; sentinel="$(_kit_rt_sentinel "$slug" "$id")"

  kit_routines_cron_remove "$sentinel" || return 1
  kit_routines_config_remove "$id" "$dir" || return 1
  _kit_rt_say "routine '$id' removed."
}

# kit_routines_verify [dir]
# Check: every id in kit.config.json .routines[] has a matching crontab entry.
# rc 0 = in sync; rc 1 = drift (missing or orphan crons).
kit_routines_verify() {
  local dir="${1:-$PWD}"
  command -v jq >/dev/null 2>&1 || kit_die "jq required"

  dir="$(cd "$dir" 2>/dev/null && pwd)" || kit_die "no such dir: $dir"
  local accepted; accepted="$(kit_routines_accepted "$dir")"
  local slug; slug="$(_kit_rt_slug "$dir")"

  if [ -z "$accepted" ]; then
    _kit_rt_say "kit-routines verify: no routines accepted — nothing to check."
    return 0
  fi

  local drift=0 id sentinel
  while IFS= read -r id; do
    [ -z "$id" ] && continue
    sentinel="$(_kit_rt_sentinel "$slug" "$id")"
    if ! kit_routines_cron_has "$sentinel"; then
      _kit_rt_say "  ! cron missing for routine '$id' (sentinel: $sentinel)"
      drift=1
    else
      _kit_rt_say "  = cron present: $id"
    fi
  done <<EOF
$accepted
EOF

  if [ "$drift" -eq 1 ]; then
    _kit_rt_say "kit-routines verify: drift detected — run 'kit-routines.sh accept <id>' to repair."
    return 1
  fi
  _kit_rt_say "kit-routines verify: all crons in sync."
  return 0
}

# kit_routines_remove_all [dir]
# Remove every kit-managed cron for this project. Called by kit-remove on uninstall.
kit_routines_remove_all() {
  local dir="${1:-$PWD}"
  command -v jq >/dev/null 2>&1 || kit_die "jq required"
  command -v crontab >/dev/null 2>&1 || { _kit_rt_say "kit-routines: crontab not found — skip cron cleanup."; return 0; }

  dir="$(cd "$dir" 2>/dev/null && pwd)" || kit_die "no such dir: $dir"
  local accepted; accepted="$(kit_routines_accepted "$dir")"
  local slug; slug="$(_kit_rt_slug "$dir")"

  if [ -z "$accepted" ]; then
    _kit_rt_say "kit-routines remove-all: no routines to remove."; return 0
  fi

  local id
  while IFS= read -r id; do
    [ -z "$id" ] && continue
    kit_routines_cron_remove "$(_kit_rt_sentinel "$slug" "$id")"
  done <<EOF
$accepted
EOF
  _kit_rt_say "kit-routines remove-all: done."
}

# ── CLI ──────────────────────────────────────────────────────────────────────
if kit_is_main; then
  command -v jq >/dev/null 2>&1 || { echo "kit-routines: jq required" >&2; exit 1; }
  _sub="${1:-}"; shift 2>/dev/null || true
  _id=""; _dir="$PWD"
  while [ $# -gt 0 ]; do case "$1" in
    --dir) _dir="$2"; shift 2;;
    --dry-run) export KIT_DRY_RUN=1; shift;;
    --yes|-y) export KIT_ASSUME_YES=1; shift;;
    -h|--help)
      echo "usage: kit-routines.sh list|accept <id>|remove <id>|verify|remove-all [--dir D] [--dry-run] [--yes]"
      exit 0;;
    -*) kit_die "unknown flag: $1";;
    *) [ -z "$_id" ] && _id="$1" || kit_die "unexpected arg: $1"; shift;;
  esac; done
  case "$_sub" in
    list)       kit_routines_list "$_dir";;
    accept)     [ -n "$_id" ] || kit_die "usage: kit-routines.sh accept <id>"; kit_routines_accept "$_id" "$_dir";;
    remove)     [ -n "$_id" ] || kit_die "usage: kit-routines.sh remove <id>"; kit_routines_remove "$_id" "$_dir";;
    verify)     kit_routines_verify "$_dir";;
    remove-all) kit_routines_remove_all "$_dir";;
    -h|--help)  echo "usage: kit-routines.sh list|accept <id>|remove <id>|verify|remove-all [--dir D] [--dry-run] [--yes]"; exit 0;;
    *) kit_die "usage: kit-routines.sh list|accept <id>|remove <id>|verify|remove-all [--dir D] [--dry-run] [--yes]";;
  esac
fi
