#!/usr/bin/env bash
# Loads .claude/kit.config.json into KIT_* environment variables.
# Source this from project scripts/skills:  source scripts/lib/kit-config.sh && load_kit_config
# Requires: jq.
#
# Per-folder overrides: any .claudekit/config.json in an ancestor directory is deep-merged over the
# project config, nearest-wins (like .editorconfig). Projects with no .claudekit/ behave unchanged.

load_kit_config() {
  local cfg="${KIT_CONFIG:-.claude/kit.config.json}"
  if [[ ! -f "$cfg" ]]; then
    echo "✗ $cfg not found. Run /kit-init (or scripts/init.sh) first." >&2
    return 1
  fi
  command -v jq >/dev/null 2>&1 || { echo "✗ jq is required." >&2; return 1; }

  export KIT_VERSION="$(jq -r '.kitVersion // "0.0.0"'  "$cfg")"

  export KIT_PROJECT_NAME="$(jq -r '.project.name'  "$cfg")"
  export KIT_PROJECT_SLUG="$(jq -r '.project.slug'  "$cfg")"
  export KIT_OWNER_NAME="$(jq -r '.project.owner'   "$cfg")"
  export KIT_LANG="$(jq -r '.project.language'      "$cfg")"
  export KIT_PROFILE="$(jq -r '.profile'            "$cfg")"
  export KIT_SKILL_PREFIX="$(jq -r '.skillPrefix // ""' "$cfg")"

  export KIT_REPO="$(jq -r '.github.repo'           "$cfg")"
  export KIT_OWNER="$(jq -r '.github.owner'         "$cfg")"
  export KIT_BASE_BRANCH="$(jq -r '.github.baseBranch // "main"' "$cfg")"  # integration branch (default main; e.g. develop)
  export KIT_PROJECTS_V2="$(jq -r '.github.projectsV2' "$cfg")"
  export KIT_PROJECT_NUMBER="$(jq -r '.github.projectNumber' "$cfg")"
  export KIT_PROJECT_TITLE="$(jq -r '.github.projectTitle'   "$cfg")"

  export KIT_PLANS_FORMAT="$(jq -r '.plans.format'  "$cfg")"
  export KIT_PLANS_DIR="$(jq -r '.plans.dir'        "$cfg")"

  export KIT_KNOWLEDGE_DIR="$(jq -r '.knowledge.dir // "knowledge"' "$cfg")"

  export KIT_MEMORY="$(jq -r '.memory.enabled'      "$cfg")"
  export KIT_WING="$(jq -r '.memory.wing'           "$cfg")"

  export KIT_SPECKIT="$(jq -r '.specKit.enabled // false'       "$cfg")"

  export KIT_ANNOTATE_ENABLED="$(jq -r '.annotate.enabled // false'  "$cfg")"
  export KIT_ANNOTATE_BACKEND="$(jq -r '.annotate.backend // ""'     "$cfg")"
  export KIT_ANNOTATE_FRAMEWORK="$(jq -r '.annotate.framework // ""' "$cfg")"

  # Local model layer (scripts/lib/kit-local.sh) — mlx_lm.server for NL chores
  export KIT_LOCAL_ENABLED="$(jq -r '.local.enabled // false' "$cfg")"
  export KIT_LOCAL_PORT="$(jq -r '.local.port // 8080'        "$cfg")"
  export KIT_LOCAL_MODEL="$(jq -r '.local.model // "mlx-community/Qwen3-8B-4bit"' "$cfg")"

  # Convenience arrays (newline-delimited)
  KIT_ROLES="$(jq -r '.roles[]? // empty'       "$cfg")"
  KIT_MILESTONES="$(jq -r '.milestones[]? // empty' "$cfg")"
  export KIT_ROLES KIT_MILESTONES

  # Apply per-folder .claudekit/ overrides (no-op when none exist).
  _kit_apply_claudekit_overlays "$cfg"
}

# Deep-merge ancestor .claudekit/config.json files over the project config (nearest-wins) and
# re-export the fields that make sense to override at folder scope. Safe no-op when none are found.
_kit_apply_claudekit_overlays() {
  local cfg="$1" proot d merged o
  local overlays=()
  proot="$(cd "$(dirname "$cfg")/.." 2>/dev/null && pwd)" || return 0

  d="$proot"
  while [[ -n "$d" && "$d" != "/" ]]; do
    [[ -f "$d/.claudekit/config.json" ]] && overlays=("$d/.claudekit/config.json" "${overlays[@]}")
    d="$(dirname "$d")"
  done
  [[ -f "/.claudekit/config.json" ]] && overlays=("/.claudekit/config.json" "${overlays[@]}")
  [[ ${#overlays[@]} -eq 0 ]] && return 0

  merged="$(cat "$cfg")"
  for o in "${overlays[@]}"; do   # far → near; jq '*' lets the right (nearer) operand win
    merged="$(jq -s '.[0] * .[1]' <(printf '%s' "$merged") "$o" 2>/dev/null || printf '%s' "$merged")"
  done

  local g; g() { printf '%s' "$merged" | jq -r "$1" 2>/dev/null; }
  export KIT_LANG="$(g '.project.language // env.KIT_LANG')"
  export KIT_PLANS_FORMAT="$(g '.plans.format // env.KIT_PLANS_FORMAT')"
  export KIT_ANNOTATE_ENABLED="$(g '.annotate.enabled // false')"
  export KIT_ANNOTATE_BACKEND="$(g '.annotate.backend // ""')"
  export KIT_ANNOTATE_FRAMEWORK="$(g '.annotate.framework // ""')"
  export KIT_EFFECTIVE_CONFIG="$merged"
}
