#!/usr/bin/env bash
# knowledge-lint.sh — knowledge-base governance guardrail (kit-owned, generic).
# Validates: required frontmatter in the knowledge dir, INDEX.md manifest completeness,
# live refs to knowledge docs, plan frontmatter + Deliverables contract.
# Config-driven via .claude/kit.config.json (knowledge.dir, plans.dir/format).
# Project-specific extra checks: scripts/knowledge-lint.local.sh (sourced if present).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
FAIL=0

err() { echo "x $1"; FAIL=1; }
ok()  { echo "ok $1"; }

# ---- config (tolerant: defaults if config/lib absent) ----------------------
KNOWLEDGE_DIR="knowledge"; PLANS_DIR=""; PLANS_FORMAT=""
if [[ -f scripts/lib/kit-config.sh && -f .claude/kit.config.json ]]; then
  source scripts/lib/kit-config.sh
  load_kit_config >/dev/null 2>&1 || true
  KNOWLEDGE_DIR="${KIT_KNOWLEDGE_DIR:-knowledge}"
  PLANS_DIR="${KIT_PLANS_DIR:-}"
  PLANS_FORMAT="${KIT_PLANS_FORMAT:-}"
fi

# ---- 1. Required frontmatter in $KNOWLEDGE_DIR/**/*.md (except INDEX.md) ---
if [[ -d "$KNOWLEDGE_DIR" ]]; then
  while IFS= read -r f; do
    if [[ "$(head -1 "$f")" != "---" ]]; then
      err "$f: missing YAML frontmatter (status/owner/updated required)"
      continue
    fi
    fm="$(awk '/^---$/{n++; next} n==1{print} n>=2{exit}' "$f")"
    for field in status owner updated; do
      echo "$fm" | grep -q "^${field}:" || err "$f: missing frontmatter field '${field}:'"
    done
    status_val="$(echo "$fm" | grep '^status:' | head -1 | sed 's/^status:[[:space:]]*//')"
    case "$status_val" in
      canonical|reference|historical|"") ;;
      *) err "$f: invalid status '$status_val' (canonical|reference|historical)" ;;
    esac
  done < <(find "$KNOWLEDGE_DIR" -name '*.md' ! -name 'INDEX.md')
  [[ $FAIL -eq 0 ]] && ok "frontmatter $KNOWLEDGE_DIR/"

  # ---- 2. INDEX.md manifest: every doc listed, every listed doc exists -----
  INDEX="$KNOWLEDGE_DIR/INDEX.md"
  if [[ ! -f "$INDEX" ]]; then
    err "$INDEX missing — the manifest is the entry point (see rules/knowledge-base.md)"
  else
    while IFS= read -r f; do
      rel="${f#"$KNOWLEDGE_DIR"/}"
      grep -q "$rel" "$INDEX" || err "INDEX.md: '$rel' not listed (new doc -> add it to the manifest in the same PR)"
    done < <(find "$KNOWLEDGE_DIR" -name '*.md' ! -name 'INDEX.md')
    while IFS= read -r listed; do
      [[ "$listed" == *NNN* ]] && continue
      [[ -f "$KNOWLEDGE_DIR/$listed" || -f "$listed" ]] || err "INDEX.md lists '$listed' but it does not exist"
    done < <(grep -oE '[A-Za-z0-9_./-]+\.md' "$INDEX" | grep -v '^INDEX\.md$' | sort -u)
  fi

  # ---- 3. Referenced knowledge paths must exist (docs surfaces only) -------
  while IFS= read -r ref; do
    [[ "$ref" == *NNN* ]] && continue
    [[ -f "$ref" ]] || err "broken ref: '$ref' (mentioned but does not exist)"
  done < <(grep -rhoE "$KNOWLEDGE_DIR/[A-Za-z0-9_/.-]+\.md" CLAUDE.md .claude/rules .claude/agents "$KNOWLEDGE_DIR" 2>/dev/null | sort -u)
fi

# ---- 4. Plans: frontmatter + Deliverables contract; no archive folder ------
if [[ -n "$PLANS_DIR" && "$PLANS_FORMAT" != "none" && -d "$PLANS_DIR" ]]; then
  # The archive folder pattern is retired: completed plans flip status:, stay visible.
  if grep -rn "$PLANS_DIR/archive" CLAUDE.md .claude "$KNOWLEDGE_DIR" "$PLANS_DIR" 2>/dev/null; then
    err "refs to '$PLANS_DIR/archive' (retired: plans flip status: Complete, no archive folder)"
  fi
  for p in "$PLANS_DIR"/*.md "$PLANS_DIR"/*.mdx; do
    [[ -e "$p" ]] || continue
    fm="$(awk '/^---$/{n++; next} n==1{print} n>=2{exit}' "$p")"
    for field in title status; do
      echo "$fm" | grep -q "^${field}:" || err "$p: missing frontmatter '${field}:'"
    done
    if ! grep -qiE '^##+ .*deliverables' "$p" && ! echo "$fm" | grep -q '^deliverables:[[:space:]]*none'; then
      err "$p: no Deliverables section and no 'deliverables: none' (the completion contract is required)"
    fi
  done
  [[ $FAIL -eq 0 ]] && ok "plans $PLANS_DIR/"
fi

# ---- 5. Project-specific extra checks (optional hook) -----------------------
if [[ -f scripts/knowledge-lint.local.sh ]]; then
  bash scripts/knowledge-lint.local.sh || FAIL=1
fi

if [[ $FAIL -ne 0 ]]; then
  echo ""
  echo "knowledge-lint FAILED — rules: $KNOWLEDGE_DIR/INDEX.md + .claude/rules/knowledge-base.md"
  exit 1
fi
echo "knowledge-lint OK"
