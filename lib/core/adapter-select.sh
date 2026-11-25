#!/usr/bin/env bash
# shellcheck shell=bash
# adapter-select.sh — which agent adapters a project runs (E257.3, #260).
#
# cckit ships two adapters in one version: Claude Code and Codex. A project selects one or both at
# `cckit init --adapter <claude|codex|both>`; the selection is stored as `adapters` in the project
# config and every later op (upgrade, wire, doctor) reads it from there instead of guessing from
# which directories happen to exist.
#
# An adapter list is a space-separated string in canonical order: "claude", "codex", "claude codex".
# A config with no `adapters` key means "claude" — every project scaffolded before this key existed.
#
#   adapter_normalize <spec>             "claude" | "codex" | "both" | "claude,codex" -> canonical list
#   adapter_union <list> <list>          both lists merged, canonical order
#   adapter_has <list> <name>            rc 0 when <name> is in <list>
#   adapter_json <list>                  the list as a JSON array
#   adapter_dir <name>                   the project dir the adapter's skills/rules live in
#   adapter_instructions <name>          the instruction file the runtime reads at the project root
#   adapter_tier <relpath>               manifest tier of an adapter-managed path (A portable, B CLI-only)
#   adapter_managed <relpath>            rc 0 when <relpath> is an adapter file init records as owned
#   adapter_list_from_config <cfg>       the stored selection ("claude" when the key is absent)
#   adapter_project_list [dir]           the selection of the project containing [dir]
#   adapter_config_existing <target>     path of <target>'s init-scaffolded config, or rc 1
#   adapter_config_default <target> <list>   where a NEW config goes for that selection
#   adapter_manifest_rel <target> <list>     the ownership manifest's path relative to <target>
#   adapter_runtime_report <list>        one "<name>\t<present|absent>\t<version>" line per adapter
#
# Requires jq for the config readers. bash 3.2 + zsh compatible: no arrays, no unquoted-variable
# word splitting (zsh does not split those).
# errors: strict — an unknown adapter name is refused, never silently dropped

adapter_normalize() {
  local spec tok c=0 x=0
  spec="$(printf '%s' "${1:-}" | tr 'A-Z,+' 'a-z  ')"
  for tok in $(printf '%s\n' "$spec"); do
    case "$tok" in
      claude)   c=1 ;;
      codex)    x=1 ;;
      both|all) c=1; x=1 ;;
      *) echo "adapter: unknown adapter '$tok' (expected claude, codex or both)" >&2; return 1 ;;
    esac
  done
  if [ "$c" = 1 ] && [ "$x" = 1 ]; then printf 'claude codex\n'
  elif [ "$c" = 1 ]; then printf 'claude\n'
  elif [ "$x" = 1 ]; then printf 'codex\n'
  else echo "adapter: no adapter named (expected claude, codex or both)" >&2; return 1
  fi
}

adapter_union() { adapter_normalize "${1:-} ${2:-}"; }

adapter_has() {
  case " ${1:-} " in *" ${2:-} "*) return 0 ;; esac
  return 1
}

adapter_json() {
  local out="" a
  for a in $(printf '%s\n' "${1:-}"); do out="${out:+$out,}\"$a\""; done
  printf '[%s]\n' "$out"
}

adapter_dir() {
  case "${1:-}" in
    claude) printf '.claude\n' ;;
    codex)  printf '.agents\n' ;;
    *) return 1 ;;
  esac
}

adapter_instructions() {
  case "${1:-}" in
    claude) printf 'CLAUDE.md\n' ;;
    codex)  printf 'AGENTS.md\n' ;;
    *) return 1 ;;
  esac
}

# Statusline shim, settings, hooks and the sigil lib only do anything inside an agent CLI (tier B):
# Claude Code for .claude/, Codex for .codex/. Instruction files, skills, rules and agents are plain
# markdown (tier A).
adapter_tier() {
  case "${1:-}" in
    .claude/statusline.sh|.claude/settings.json|.claude/hooks/*|.claude/lib/*|.codex/hooks.json|.codex/hooks/*) printf 'B\n' ;;
    *) printf 'A\n' ;;
  esac
}

# The adapter files init records in the ownership manifest. NOT the project config and NOT
# settings.local.json: the first is the project's own record, the second is per-checkout and
# gitignored, and neither is something `cckit remove` should treat as a kit artifact. Under .codex/
# only the hook scripts, hooks.json (E257.5) and the role agents init wrote (E257.6) are cckit's;
# config.toml and the rest is the user's Codex setup. init records hooks.json only when it created
# the file or the manifest still proves it unmodified.
adapter_managed() {
  case "${1:-}" in
    .claude/kit.config.json|.claude/kit.manifest.json|.claude/settings.local.json) return 1 ;;
    CLAUDE.md|AGENTS.md|.claude/*|.agents/skills/*|.agents/rules/*|.codex/hooks.json|.codex/hooks/*|.codex/agents/*) return 0 ;;
  esac
  return 1
}

adapter_list_from_config() {
  local cfg="${1:-}" raw
  [ -f "$cfg" ] || { printf 'claude\n'; return 0; }
  command -v jq >/dev/null 2>&1 || { printf 'claude\n'; return 0; }
  raw="$(jq -r 'if has("adapters") then (.adapters | if type == "array" then join(" ") else tostring end) else "claude" end' "$cfg" 2>/dev/null)" \
    || { echo "adapter: cannot read adapters from $cfg" >&2; return 1; }
  adapter_normalize "$raw"
}

adapter_project_list() {
  local cfg=""
  if command -v kit_config_path >/dev/null 2>&1; then cfg="$(kit_config_path "${1:-$PWD}" 2>/dev/null || true)"; fi
  adapter_list_from_config "$cfg"
}

# A root cckit.config.json counts as init-scaffolded only when it carries `adapters`: that is the
# layout init writes for a Codex-only project. A root config without the key is the self-host layout
# (cckit's own repo), which init must keep refusing to upgrade over.
adapter_config_existing() {
  local t="${1:-.}"
  if [ -f "$t/cckit.config.json" ] && command -v jq >/dev/null 2>&1 \
     && jq -e 'has("adapters")' "$t/cckit.config.json" >/dev/null 2>&1; then
    printf '%s\n' "$t/cckit.config.json"; return 0
  fi
  if [ -f "$t/.claude/kit.config.json" ]; then printf '%s\n' "$t/.claude/kit.config.json"; return 0; fi
  return 1
}

# A project that selects Claude keeps the layout every existing project has. A Codex-only project
# gets no .claude/ tree at all, so its config goes to the adapter-neutral root file the resolver
# (config-path.sh) already checks first.
adapter_config_default() {
  if adapter_has "${2:-}" claude; then printf '%s\n' "${1:-.}/.claude/kit.config.json"
  else printf '%s\n' "${1:-.}/cckit.config.json"; fi
}

# The manifest stays wherever the first install put it — enabling a second adapter never moves it.
adapter_manifest_rel() {
  local t="${1:-.}"
  if [ -f "$t/.claude/kit.manifest.json" ]; then printf '.claude/kit.manifest.json\n'
  elif [ -f "$t/.cckit/kit.manifest.json" ]; then printf '.cckit/kit.manifest.json\n'
  elif adapter_has "${2:-}" claude; then printf '.claude/kit.manifest.json\n'
  else printf '.cckit/kit.manifest.json\n'; fi
}

adapter_runtime_report() {
  local a ver
  for a in $(printf '%s\n' "${1:-}"); do
    if command -v "$a" >/dev/null 2>&1; then
      ver="$("$a" --version 2>/dev/null | sed -n 1p)"
      printf '%s\tpresent\t%s\n' "$a" "${ver:-version unknown}"
    else
      printf '%s\tabsent\t\n' "$a"
    fi
  done
}
