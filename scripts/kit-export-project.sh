#!/usr/bin/env bash
# kit-export-project.sh — export a kit project to the two non-terminal Claude surfaces (#376).
#
# THE GOAL (the acceptance gate): the SAME project runs in three places with NO hand edits —
#   1. terminal   — Claude Code reads CLAUDE.md + .claude/ natively (the home surface).
#   2. Cowork     — Claude Code in the cloud; reads the same CLAUDE.md + .claude/ tree natively.
#   3. claude.ai  — a Project has TWO slots (no .claude/ tree): "custom instructions" (one text box)
#                   + "project knowledge" (uploaded files). It cannot run scripts.
#
# Terminal + Cowork need NOTHING from this tool — they read the repo as-is. The only surface that
# needs a transform is claude.ai, because it has no filesystem: we FLATTEN CLAUDE.md (resolving its
# @-imports of .claude/rules/*) into ONE instructions file, and COPY the knowledge corpus into an
# upload-ready folder. We also VERIFY Cowork compat (every file the project leans on is tier-A
# portable, not a tier-B CLI-only shim) and print a support matrix.
#
# TIER MODEL (#373, recorded in .claude/kit.manifest.json):
#   tier A = portable  — skills/rules/agents/commands; meaningful in Cowork AND claude.ai.
#   tier B = CLI-only  — statusline.sh / settings.json / hooks/ / lib/ ; need a terminal+filesystem.
# The export carries ONLY tier-A semantics to claude.ai; a tier-B file the project REQUIRES to
# function is a portability defect we flag (it would silently no-op off-terminal).
#
# OUTPUT (default .kit-export/, override with --out DIR):
#   claude-instructions.md   the flattened CLAUDE.md + inlined @.claude/rules/* — paste into the
#                            claude.ai Project's "custom instructions" box.
#   project-knowledge/       knowledge/** (+ agents/ + rules/ as reference) — upload as Project knowledge.
#   SUPPORT-MATRIX.md        terminal / Cowork / claude.ai feature support, generated from the manifest.
#
# Run:
#   scripts/kit-export-project.sh                 # full export to .kit-export/
#   scripts/kit-export-project.sh --out build/x   # custom output dir
#   scripts/kit-export-project.sh --verify        # Cowork+claude.ai compat check only, write nothing (rc 1 on defect)
#   scripts/kit-export-project.sh --matrix        # print the support matrix to stdout, write nothing
#   scripts/kit-export-project.sh --dry-run       # report what it would write, write nothing
# Requires: jq + a sha256 tool (for tier lookups via the manifest).

set -uo pipefail
_export_dir="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=/dev/null
. "$_export_dir/lib/kit-cli.sh"        # kit_is_main
# shellcheck source=/dev/null
. "$_export_dir/lib/kit-manifest.sh"   # tier lookups

_kex_say() { printf '%s\n' "$*" >&2; }

# Tier-classify a kit-shaped path the same way kit-wire/kit-adopt do — manifest first (authoritative,
# carries the tier the file was wired with), heuristic fallback when the file isn't manifest-tracked
# (e.g. a hand-imported project that never ran kit-adopt).
kit_export_tier() {
  local p="$1" t
  t="$(kit_manifest_get "$p" 2>/dev/null | jq -r '.tier // empty' 2>/dev/null || true)"
  if [ -n "$t" ]; then printf '%s\n' "$t"; return 0; fi
  case "$p" in
    .claude/statusline.sh|.claude/settings.json|.claude/settings.local.json|.claude/hooks/*|.claude/lib/*) printf 'B\n' ;;
    *) printf 'A\n' ;;
  esac
}

# Resolve a Claude `@path` import to a relpath. Claude Code imports are written `@.claude/rules/x.md`
# or `@./KIT.md`; strip the leading @ and any ./ — return empty for a non-import line.
_kex_import_path() {
  case "$1" in
    @*) printf '%s\n' "${1#@}" | sed 's#^\./##' ;;
    *)  printf '\n' ;;
  esac
}

# Flatten CLAUDE.md into a single instructions document for claude.ai. We INLINE every @-import
# (the .claude/rules/* and any @./KIT.md) so the one text box carries the whole instruction set —
# claude.ai can't follow an @ to a file it doesn't have. Imports are inlined ONCE (dedup) and only
# tier-A files are inlined (a tier-B shim has no meaning without a terminal). Non-import lines pass
# through verbatim. Recurses one level into imported rule files (they rarely chain, but we guard a
# seen-set so a cycle can't loop).
kit_export_flatten_instructions() {
  local claude_md="${1:-CLAUDE.md}"
  [ -f "$claude_md" ] || { _kex_say "kit-export: $claude_md not found"; return 1; }

  # seen-set for dedup/cycle-guard (newline-delimited paths already inlined)
  local seen=""
  _kex_emit_file() {  # <relpath> <depth>
    local f="$1" depth="$2" line ip tier
    case "$seen" in *"|$f|"*) return 0 ;; esac
    seen="$seen|$f|"
    while IFS= read -r line || [ -n "$line" ]; do
      ip="$(_kex_import_path "$line")"
      if [ -n "$ip" ] && [ -f "$ip" ] && [ "$depth" -lt 4 ]; then
        tier="$(kit_export_tier "$ip")"
        if [ "$tier" = "A" ]; then
          printf '\n<!-- inlined from %s (tier A) -->\n' "$ip"
          _kex_emit_file "$ip" $((depth + 1))
        else
          printf '\n<!-- skipped %s (tier B — CLI-only, no meaning on claude.ai) -->\n' "$ip"
        fi
      else
        printf '%s\n' "$line"
      fi
    done < "$f"
  }

  printf '<!-- Generated by kit-export-project (#376) — paste into the claude.ai Project custom-instructions box. -->\n'
  printf '<!-- Source: %s + inlined @.claude/rules/* (tier-A). Terminal/Cowork read the repo directly. -->\n\n' "$claude_md"
  _kex_emit_file "$claude_md" 0
}

# Cowork + claude.ai compat verdict. Cowork runs Claude Code natively, so the question is: does the
# project FUNCTION when only the portable (tier-A) surface is honored? Any file CLAUDE.md imports
# that is tier-B is a portability defect (it silently no-ops off-terminal). rc 0 = portable, 1 = defect.
kit_export_verify() {
  local claude_md="${1:-CLAUDE.md}" defects=0 line ip tier
  if [ ! -f "$claude_md" ]; then _kex_say "kit-export --verify: $claude_md not found"; return 1; fi
  _kex_say "kit-export --verify: checking that the portable surface is self-sufficient..."
  while IFS= read -r line || [ -n "$line" ]; do
    ip="$(_kex_import_path "$line")"
    [ -n "$ip" ] || continue
    if [ ! -f "$ip" ]; then
      _kex_say "  ! CLAUDE.md imports $ip but it is MISSING — broken on every surface"
      defects=$((defects + 1)); continue
    fi
    tier="$(kit_export_tier "$ip")"
    if [ "$tier" = "B" ]; then
      _kex_say "  ! CLAUDE.md requires $ip (tier B / CLI-only) — silently no-ops in Cowork/claude.ai"
      defects=$((defects + 1))
    else
      _kex_say "  ok $ip (tier A — portable)"
    fi
  done < "$claude_md"
  if [ "$defects" -eq 0 ]; then
    _kex_say "kit-export --verify: PORTABLE — the same project runs in terminal / Cowork / claude.ai with no hand edits."
    return 0
  fi
  _kex_say "kit-export --verify: $defects portability defect(s) — fix before relying on the non-terminal surfaces."
  return 1
}

# The support matrix — what each surface can do, generated from the manifest tiers present.
kit_export_matrix() {
  local a_count b_count
  a_count="$(kit_manifest_list A 2>/dev/null | grep -c . || true)"
  b_count="$(kit_manifest_list B 2>/dev/null | grep -c . || true)"
  cat <<MATRIX
# claude-kit surface support matrix

Generated by kit-export-project (#376). The kit project runs on three Claude surfaces; this table
records what each supports and how the project gets there.

| Capability                          | Terminal (Claude Code) | Cowork (cloud Claude Code) | claude.ai Project |
| ----------------------------------- | :--------------------: | :------------------------: | :---------------: |
| Reads CLAUDE.md + .claude/ natively |           yes          |             yes            |  no (no FS)       |
| Tier-A skills / rules / agents      |           yes          |             yes            |  via export*      |
| Tier-B statusline / hooks / settings|           yes          |          partial**         |  no               |
| Runs \`kit\` / \`scripts/*\` verbs     |           yes          |             yes            |  no (can't shell) |
| GitHub lifecycle (gh, worktrees)    |           yes          |             yes            |  no               |
| Knowledge corpus available          |        in repo         |           in repo          |  via export*      |

\* claude.ai has no filesystem: run \`kit-export-project\` → paste \`claude-instructions.md\` into the
  Project custom-instructions box and upload \`project-knowledge/\` as Project knowledge.
\*\* Cowork runs Claude Code but a shim like the statusline / a guard hook may be inert in that
  environment; the PROJECT still functions because tier-B files are conveniences, not requirements
  (verified by \`kit-export-project --verify\`).

## This project's manifest tiering
- Tier A (portable): ${a_count} file(s)
- Tier B (CLI-only): ${b_count} file(s)

Tier A = portable to Cowork AND claude.ai. Tier B = needs a terminal + filesystem. The export
carries only tier-A semantics off-terminal; a tier-B file the project *requires* is a defect
\`--verify\` flags.
MATRIX
}

# Copy the knowledge corpus + portable reference files into an upload-ready folder for claude.ai.
# Honors KIT_DRY_RUN. Knowledge dir is config-resolved (defaults to knowledge/).
kit_export_knowledge() {
  local out="$1" kdir="${2:-knowledge}" copied=0
  local dest="$out/project-knowledge"
  if [ -n "${KIT_DRY_RUN:-}" ]; then
    [ -d "$kdir" ] && _kex_say "  [dry-run] would copy $kdir/** -> $dest/"
    _kex_say "  [dry-run] would copy .claude/rules/ + .claude/agents/ (tier-A reference) -> $dest/"
    return 0
  fi
  mkdir -p "$dest"
  if [ -d "$kdir" ]; then
    # -R preserves the knowledge/ tree under the dest; portable on bash + zsh, macOS + linux cp.
    cp -R "$kdir" "$dest/" && copied=1
  fi
  # Carry tier-A reference material (rules + agents) so a claude.ai Project has the same context.
  [ -d .claude/rules ]  && cp -R .claude/rules  "$dest/" 2>/dev/null && copied=1
  [ -d .claude/agents ] && cp -R .claude/agents "$dest/" 2>/dev/null && copied=1
  if [ "$copied" -eq 1 ]; then
    _kex_say "  knowledge + tier-A reference copied -> $dest/"
  else
    _kex_say "  (no knowledge/ or tier-A reference found to copy)"
  fi
}

# Full export: instructions + knowledge + matrix into OUT.
kit_export_all() {
  local out="$1" kdir="${2:-knowledge}"
  command -v jq >/dev/null 2>&1 || { _kex_say "kit-export: jq required"; return 1; }
  [ -f CLAUDE.md ] || { _kex_say "kit-export: no CLAUDE.md here — run from the project root (or /kit-init first)."; return 1; }

  _kex_say "kit-export: exporting to $out/ (terminal/Cowork read the repo directly; this is for claude.ai)"

  if [ -n "${KIT_DRY_RUN:-}" ]; then
    _kex_say "  [dry-run] would write $out/claude-instructions.md (flattened CLAUDE.md + tier-A rules)"
    kit_export_knowledge "$out" "$kdir"
    _kex_say "  [dry-run] would write $out/SUPPORT-MATRIX.md"
    return 0
  fi

  mkdir -p "$out"
  kit_export_flatten_instructions CLAUDE.md > "$out/claude-instructions.md" \
    && _kex_say "  wrote $out/claude-instructions.md"
  kit_export_knowledge "$out" "$kdir"
  kit_export_matrix > "$out/SUPPORT-MATRIX.md" && _kex_say "  wrote $out/SUPPORT-MATRIX.md"

  _kex_say "kit-export: done."
  _kex_say "  -> paste $out/claude-instructions.md into the claude.ai Project custom-instructions box"
  _kex_say "  -> upload $out/project-knowledge/ as the Project's knowledge"
  # A portability nudge: report (don't fail) if the verify check finds defects.
  kit_export_verify CLAUDE.md >/dev/null 2>&1 || _kex_say "  note: run --verify — the portable surface has defect(s)."
}

# CLI (direct execution only; sourcing exposes the functions for tests)
if kit_is_main; then
  _mode=export _out=".kit-export" _kdir="knowledge"
  # config-resolve the knowledge dir if available (kit-config.sh ships alongside in scripts/lib)
  if [ -f "$_export_dir/lib/kit-config.sh" ]; then
    # shellcheck source=/dev/null
    . "$_export_dir/lib/kit-config.sh"
    load_kit_config >/dev/null 2>&1 && _kdir="${KIT_KNOWLEDGE_DIR:-knowledge}" || true
  fi
  while [ $# -gt 0 ]; do case "$1" in
    --out)     _out="${2:?--out needs a dir}"; shift 2;;
    --verify)  _mode=verify; shift;;
    --matrix)  _mode=matrix; shift;;
    --dry-run) export KIT_DRY_RUN=1; shift;;
    -h|--help) sed -n '/^# Run:/,/^# Requires:/p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac; done
  case "$_mode" in
    verify) kit_export_verify CLAUDE.md;;
    matrix) kit_export_matrix;;
    *)      kit_export_all "$_out" "$_kdir";;
  esac
fi
