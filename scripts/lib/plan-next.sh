#!/usr/bin/env bash
# plan-next.sh — the forward planner (Effort 86 · #87/#88). cckit's "given where we are, here is what
# to build next" triage, productized. It introspects the CURRENT capability surface — skills,
# commands/verbs, rules, docs — at runtime and proposes concrete next efforts grounded in what the
# kit can already do. Run against cckit itself (full inventory) or any project the kit is installed
# in (degrades to whatever capability dirs exist, never crashes).
#
#   cckit plan-next                current capabilities + a proposed forward plan (markdown)
#   cckit plan-next --llm          the proposed plan as TOON rows {rank,area,proposal,next} (JSON fallback)
#   cckit plan-next --root <dir>   scan <dir> instead of the resolved project/kit root
#
# CRITICAL — context-anxiety rule: this output is HUMAN / orchestrator-facing ONLY. It is NEVER to
# be injected into a monitored model's prompt or context. The planner pre-grounds planning in the
# current docs/skills/rules so the EXECUTING agent burns fewer tokens rediscovering context — it is
# not itself agent-context fuel. The verb and the skill both honor this; see rules/plan-next.md.
#
# Filesystem-only — needs jq only for --llm (TOON/JSON). bash 3.2 / zsh compatible.

# _pn_first_dir <dir> [dir …] — echo the first directory that exists (graceful host-project fallback).
_pn_first_dir() {
  local d
  for d in "$@"; do [ -n "$d" ] && [ -d "$d" ] && { printf '%s' "$d"; return 0; }; done
  return 1
}

# plan_next_skills_dir / _rules_dir / _docs_dir <root> — resolve the capability dir for one area,
# trying cckit's own layout first, then the installed-in-a-project layout. Empty when none exist.
plan_next_skills_dir() { _pn_first_dir "$1/skills" "$1/.claude/skills" 2>/dev/null; }
plan_next_rules_dir()  { _pn_first_dir "$1/rules" "$1/templates/rules" "$1/.claude/rules" 2>/dev/null; }
plan_next_docs_dir()   { _pn_first_dir "$1/docs-site/src/content/docs" "$1/docs" "$1/.claude/docs" 2>/dev/null; }

# plan_next_skills <root> — one skill name per line (the SKILL.md parent dir basename), sorted.
plan_next_skills() {
  local dir; dir="$(plan_next_skills_dir "$1")" || return 0
  local f
  for f in "$dir"/*/SKILL.md; do
    [ -f "$f" ] || continue
    basename "$(dirname "$f")"
  done | sort -u
}

# plan_next_rules <root> — one rule name per line (the .md basename without extension), sorted.
plan_next_rules() {
  local dir; dir="$(plan_next_rules_dir "$1")" || return 0
  local f b
  for f in "$dir"/*.md; do
    [ -f "$f" ] || continue
    b="$(basename "$f")"; printf '%s\n' "${b%.md}"
  done | sort -u
}

# plan_next_verbs <root> — one verb per line. Prefer the cckit dispatcher's own case labels (the
# single source of truth, same parse as `cckit commands`); fall back to a commands/ listing when run
# in a host project that has no bin/cckit.
plan_next_verbs() {
  local root="$1"
  if [ -f "$root/bin/cckit" ]; then
    grep -oE '^  [a-z][a-z|-]*\)' "$root/bin/cckit" \
      | sed 's/[) ]//g' | tr '|' '\n' | grep -vE '^(-|$)' | sort -u
    return 0
  fi
  local dir; dir="$(_pn_first_dir "$root/commands" "$root/.claude/commands" 2>/dev/null)" || return 0
  local f b
  for f in "$dir"/*.md; do
    [ -f "$f" ] || continue
    b="$(basename "$f")"; printf '%s\n' "${b%.md}"
  done | sort -u
}

# plan_next_docs <root> — one doc name per line (the .md/.mdx basename without extension), sorted.
plan_next_docs() {
  local dir; dir="$(plan_next_docs_dir "$1")" || return 0
  local f b
  for f in "$dir"/*.md "$dir"/*.mdx; do
    [ -f "$f" ] || continue
    b="$(basename "$f")"; b="${b%.mdx}"; printf '%s\n' "${b%.md}"
  done | sort -u
}

# _pn_docs_blob <root> — all doc text concatenated + lowercased, for coverage-gap detection.
_pn_docs_blob() {
  local dir; dir="$(plan_next_docs_dir "$1")" || return 0
  cat "$dir"/*.md "$dir"/*.mdx 2>/dev/null | tr '[:upper:]' '[:lower:]'
}

# _pn_root — the directory to scan. PLAN_NEXT_ROOT wins (tests / explicit), else the project root
# inferred from KIT_CONFIG (parent of a .claude/ config), else $PWD. In cckit this is the cckit repo;
# in a host project it is that project — so the inventory is always "this project's capabilities".
_pn_root() {
  if [ -n "${PLAN_NEXT_ROOT:-}" ]; then printf '%s' "$PLAN_NEXT_ROOT"; return 0; fi
  local cfg="${KIT_CONFIG:-}" d
  if [ -n "$cfg" ] && [ -f "$cfg" ]; then
    d="$(cd "$(dirname "$cfg")" 2>/dev/null && pwd)" || d=""
    case "$d" in */.claude) d="$(dirname "$d")" ;; esac
    [ -n "$d" ] && { printf '%s' "$d"; return 0; }
  fi
  printf '%s' "$PWD"
}

# _pn_proposals <root> — the forward plan as TSV rows: rank<TAB>area<TAB>proposal<TAB>next.
# Deterministic + grounded in the inventory. ALWAYS emits the mandatory docs + README item first
# (docs-always rule — never dropped, even for a tiny change). Then up to 3 concrete coverage gaps
# (skills/verbs not referenced anywhere in the docs), then a thinnest-area suggestion so there is
# always >=1 concrete next effort beyond docs. Capped so the plan stays scannable.
_pn_proposals() {
  local root="$1" rank=1
  local handoff="/kit-effort-new"

  # 1. MANDATORY — docs + README. Non-negotiable, always present (asserted by tests).
  printf '%s\tdocs\t%s\t%s\n' "$rank" \
    "Update the docs site + README + AGENTS for the latest work (mandatory, never skipped)" "$handoff"
  rank=$((rank + 1))

  # 2. Coverage gaps — capabilities not yet mentioned anywhere in the docs (grounded in current state).
  local blob s v added=0
  blob="$(_pn_docs_blob "$root")"
  for s in $(plan_next_skills "$root"); do
    [ "$added" -ge 3 ] && break
    case "$blob" in *"$s"*) ;; *)
      printf '%s\tskills\t%s\t%s\n' "$rank" "Document the $s skill — it is not referenced in any doc page" "$handoff"
      rank=$((rank + 1)); added=$((added + 1)) ;;
    esac
  done
  for v in $(plan_next_verbs "$root"); do
    [ "$added" -ge 3 ] && break
    case "$blob" in *"$v"*) ;; *)
      printf '%s\tcommands\t%s\t%s\n' "$rank" "Add the '$v' verb to the CLI reference — it ships but is undocumented" "$handoff"
      rank=$((rank + 1)); added=$((added + 1)) ;;
    esac
  done

  # 3. Thinnest-area suggestion — guarantees a concrete non-docs proposal even when coverage is clean.
  local cs cv cr thin tn
  cs="$(plan_next_skills "$root" | grep -c .)"
  cv="$(plan_next_verbs "$root"  | grep -c .)"
  cr="$(plan_next_rules "$root"  | grep -c .)"
  thin="skills"; tn="$cs"
  [ "$cv" -lt "$tn" ] && { thin="commands"; tn="$cv"; }
  [ "$cr" -lt "$tn" ] && { thin="rules"; tn="$cr"; }
  printf '%s\t%s\t%s\t%s\n' "$rank" "$thin" \
    "Deepen the thinnest area '$thin' ($tn entries) — propose one new capability there" "$handoff"
}

# plan_next — the verb body. Human markdown by default; TOON/JSON under --llm. Never injects into
# any agent context (context-anxiety rule).
plan_next() {
  local out="${CCKIT_OUTPUT:-human}" root=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --llm|--output=json) out="json"; shift ;;
      --root)   root="$2"; shift 2 ;;
      --root=*) root="${1#*=}"; shift ;;
      -h|--help) sed -n '8,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; return 0 ;;
      *) if [ "$out" = "json" ]; then _pn_err "unknown arg '$1'"; else echo "plan-next: unknown arg '$1'" >&2; fi; return 2 ;;
    esac
  done
  [ -n "$root" ] && PLAN_NEXT_ROOT="$root"
  root="$(_pn_root)"

  # --llm needs jq for valid TOON/JSON — emit a structured error rather than malformed output.
  if [ "$out" = "json" ] && ! command -v jq >/dev/null 2>&1; then
    printf '{"error":"plan-next: jq is required for --llm output"}\n'; return 1
  fi

  local skills verbs rules docs cs cv cr cd total
  skills="$(plan_next_skills "$root")"; cs="$(printf '%s' "$skills" | grep -c .)"
  verbs="$(plan_next_verbs  "$root")"; cv="$(printf '%s' "$verbs"  | grep -c .)"
  rules="$(plan_next_rules  "$root")"; cr="$(printf '%s' "$rules"  | grep -c .)"
  docs="$(plan_next_docs    "$root")"; cd="$(printf '%s' "$docs"   | grep -c .)"
  total=$((cs + cv + cr + cd))

  local proposals; proposals="$(_pn_proposals "$root")"

  if [ "$out" = "json" ]; then
    # TOON rows {rank,area,proposal,next}. Always >=1 row (the mandatory docs item), so the plan is
    # never empty; the explicit empty state is the capability inventory being bare (total==0), which
    # the human view surfaces and the rule documents. The 'next' field carries the next-step handoff.
    local here json; here="$(dirname "${BASH_SOURCE[0]}")"
    json="$(printf '%s\n' "$proposals" \
      | jq -R -s '[ split("\n")[] | select(length>0) | split("\t")
                    | {rank:(.[0]|tonumber), area:.[1], proposal:.[2], next:.[3]} ]')"
    # shellcheck source=/dev/null
    . "$here/toon.sh"
    printf '%s' "$json" | toon_encode
    return 0
  fi

  # human: current capabilities + the proposed plan, through the rendering seam (#82). Leads with
  # human-meaningful names; no `--llm` decoration in the prose (house presentation rule).
  local here; here="$(dirname "${BASH_SOURCE[0]}")"
  # shellcheck source=/dev/null
  . "$here/render.sh" 2>/dev/null || true
  local name; name="$(basename "$root")"
  _pn_human() {
    printf '# Plan next — %s\n\n' "$name"
    if [ "$total" -eq 0 ]; then
      printf '> No kit capabilities found here — this looks like a host project with no skills, verbs,\n'
      printf '> rules, or docs yet. The plan below still carries the mandatory docs + README step; run\n'
      printf '> from the cckit repo (or scaffold with `cckit init`) for a full forward plan.\n\n'
    fi
    printf '## Current capabilities\n\n'
    printf '| area | count | sample |\n| --- | --- | --- |\n'
    printf '| skills | %s | %s |\n'   "$cs" "$(printf '%s' "$skills" | head -3 | tr '\n' ' ' | sed 's/ $//')"
    printf '| commands | %s | %s |\n' "$cv" "$(printf '%s' "$verbs"  | head -3 | tr '\n' ' ' | sed 's/ $//')"
    printf '| rules | %s | %s |\n'    "$cr" "$(printf '%s' "$rules"  | head -3 | tr '\n' ' ' | sed 's/ $//')"
    printf '| docs | %s | %s |\n'     "$cd" "$(printf '%s' "$docs"   | head -3 | tr '\n' ' ' | sed 's/ $//')"
    printf '\n## Proposed next — grounded in the above\n\n'
    printf '| rank | area | proposal |\n| --- | --- | --- |\n'
    printf '%s\n' "$proposals" | awk -F'\t' 'NF>=3 { printf "| %s | %s | %s |\n", $1, $2, $3 }'
    printf '\n## Next step\n\n'
    printf 'Pick an item and scope it into an effort with `/kit-plan-next` (conversational), or directly:\n\n'
    printf '```\n/kit-effort-new\n```\n\n'
    printf '> This plan is human / orchestrator-facing only — never paste it into a monitored agent'\''s\n'
    printf '> context (context-anxiety rule). See rules/plan-next.md.\n'
  }
  if command -v cckit_render >/dev/null 2>&1; then _pn_human | cckit_render; else _pn_human; fi
}

# _pn_err — structured error for --llm mode (mirrors the other verbs' failure shape).
_pn_err() { printf '{"error":"plan-next: %s"}\n' "$1"; }
