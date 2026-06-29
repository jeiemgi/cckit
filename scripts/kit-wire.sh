#!/usr/bin/env bash
# kit-wire.sh — idempotent "converge" that installs/repairs everything the kit must WIRE into a
# project, and keeps it wired across updates (#369). Fixes the live class of bug where /kit-update
# refreshes files but never re-runs the wiring, so settings drift and engine assets go stale.
#
# WHAT IT CONVERGES (each recorded in the F0 ownership manifest, so update/uninstall stay safe):
#   1. statusline shim     .claude/statusline.sh  -> a STABLE file that exec's the plugin's
#                          versioned kit-statusline.sh. The shim never changes, so a plugin bump
#                          updates the statusline everywhere with zero local edits (kills the
#                          "template drifted older than the project copy" bug).
#   2. settings statusLine  ensures .claude/settings.json points its statusLine at the shim.
#   3. hook executability    chmod +x on managed hooks so they actually run.
#
# Run:   scripts/kit-wire.sh            # converge (interactive confirms unless KIT_ASSUME_YES)
#        scripts/kit-wire.sh --check    # report drift only, write nothing (rc 1 if drift) — self-heal
#        KIT_ASSUME_YES=1 scripts/kit-wire.sh   # non-interactive (init/update/CI)
#
# Idempotent: a second run is a no-op. Honors KIT_DRY_RUN. Requires: jq.

set -uo pipefail
_wire_dir="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=/dev/null
. "$_wire_dir/lib/kit-operate.sh"   # pulls in kit-manifest.sh too
# shellcheck source=/dev/null
. "$_wire_dir/lib/kit-cli.sh"       # kit_is_main

# Where the running engine lives. As a Claude Code plugin, CLAUDE_PLUGIN_ROOT is set; otherwise
# fall back to this script's plugin dir (two levels up from scripts/).
kit_plugin_root() {
  if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; return 0; fi
  ( CDPATH='' cd -- "$_wire_dir/.." && pwd )
}

# The shim is intentionally tiny and STABLE — its content never encodes a version, so it survives
# plugin bumps. It resolves the newest installed kit plugin by glob and exec's its statusline.
# (Falls back to a co-located plugin root for dev/source checkouts.)
_kit_shim_content() {
  cat <<'SHIM'
#!/usr/bin/env bash
# claude-kit statusline shim — DO NOT EDIT. Managed by `kit-wire` (kit.manifest.json).
# Stable indirection: resolves the installed kit plugin and exec's its versioned statusline,
# so a plugin update changes the statusline with no edit here. Fails soft (exit 0).
set -uo pipefail
_p="${CLAUDE_PLUGIN_ROOT:-}"
if [ -z "$_p" ]; then
  _p="$(ls -d "$HOME"/.claude/plugins/cache/*/claude-kit*/ 2>/dev/null | sort -V | tail -1)"
fi
_sl="$_p/statusline/kit-statusline.sh"
[ -f "$_sl" ] || _sl="$_p/templates/statusline/kit-statusline.sh"
if [ -f "$_sl" ]; then exec bash "$_sl" "$@"; fi
cat >/dev/null 2>&1; exit 0   # no engine found: consume stdin, render nothing, never error
SHIM
}

# Ensure .claude/settings.json has statusLine -> the shim. Uses jq; creates the file if absent.
_kit_wire_settings() {
  local settings=".claude/settings.json" shim=".claude/statusline.sh" cmd tmp cur want
  cmd="\$CLAUDE_PROJECT_DIR/$shim"
  if _kit_op_dry; then
    cur="$(jq -r '.statusLine.command // empty' "$settings" 2>/dev/null || true)"
    [ "$cur" = "$cmd" ] && { _kit_op_say "= settings.statusLine already wired"; return 0; }
    _kit_op_say "~ would set settings.statusLine -> $cmd"; return 10
  fi
  [ -f "$settings" ] || printf '{}\n' > "$settings"
  cur="$(jq -r '.statusLine.command // empty' "$settings" 2>/dev/null || true)"
  if [ "$cur" = "$cmd" ]; then _kit_op_say "= settings.statusLine already wired"; return 0; fi
  tmp="$(mktemp)" || return 1
  jq --arg c "$cmd" '.statusLine = {type:"command", command:$c}' "$settings" > "$tmp" \
    && mv "$tmp" "$settings" || { rm -f "$tmp"; return 1; }
  kit_manifest_record "$settings" B wire >/dev/null 2>&1 || true
  _kit_op_say "+ wired settings.statusLine -> $cmd"
}

# chmod +x any managed hooks present under .claude/hooks (so they actually run).
_kit_wire_hook_exec() {
  local h changed=0
  [ -d ".claude/hooks" ] || return 0
  for h in .claude/hooks/*.sh; do
    [ -f "$h" ] || continue
    if [ ! -x "$h" ]; then
      _kit_op_dry && { _kit_op_say "~ would chmod +x $h"; changed=1; continue; }
      chmod +x "$h" && _kit_op_say "+ chmod +x $h" && changed=1
    fi
  done
  return 0
}

kit_wire() {
  command -v jq >/dev/null 2>&1 || { echo "kit-wire: jq required" >&2; return 1; }
  local proot shim=".claude/statusline.sh"
  proot="$(kit_plugin_root)"
  _kit_op_say "kit-wire: plugin root = $proot"
  mkdir -p .claude
  # 1. statusline shim (tier B — CLI only). kit_op_write_content runs the conffiles machine.
  _kit_shim_content | kit_op_write_content "$shim" B wire || return 1
  [ -f "$shim" ] && [ -z "${KIT_DRY_RUN:-}" ] && chmod +x "$shim"
  # 2. settings statusLine -> shim
  _kit_wire_settings || true
  # 3. hook executability
  _kit_wire_hook_exec || true
}

# --check: report drift, write nothing, rc 1 if anything is out of sync (for SessionStart self-heal)
# Also verifies that every accepted routine in kit.config.json has a matching cron entry.
kit_wire_check() {
  local drift=0
  # 1. standard wire drift
  KIT_DRY_RUN=1 kit_wire >/tmp/.kitwire.$$ 2>&1
  if grep -qE '^[~+]|would' /tmp/.kitwire.$$; then
    sed 's/^/  /' /tmp/.kitwire.$$ >&2; drift=1
  fi
  rm -f /tmp/.kitwire.$$
  # 2. routines: check accepted crons are installed (fail-soft — missing crontab is not an error)
  if command -v crontab >/dev/null 2>&1; then
    local rt_script; rt_script="$(kit_plugin_root)/scripts/kit-routines.sh"
    if [ -f "$rt_script" ]; then
      bash "$rt_script" verify 2>/tmp/.kiwire-rt.$$ || { sed 's/^/  /' /tmp/.kiwire-rt.$$ >&2; drift=1; }
      rm -f /tmp/.kiwire-rt.$$
    fi
  fi
  return "$drift"
}

# CLI (direct execution only; zsh-safe guard)
# CLI (direct execution only)
if kit_is_main; then
  case "${1:-}" in
    --check) kit_wire_check;;
    -h|--help) echo "usage: kit-wire.sh [--check]   (env: KIT_ASSUME_YES, KIT_DRY_RUN)";;
    *) kit_wire;;
  esac
fi
