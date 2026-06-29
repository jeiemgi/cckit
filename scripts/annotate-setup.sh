#!/usr/bin/env bash
# claude-kit — wire Agentation (in-app visual UI annotation) into a React project, for Claude Code.
# Installs the third-party `agentation` dev dependency, registers the `agentation-mcp` MCP server
# for Claude, writes the react-annotate rule, and records the choice in .claude/kit.config.json.
# It PRINTS the dev-only provider snippet to add to the app entry — the /kit-annotate skill applies
# that source edit with your confirmation (layouts vary too much for a safe blind sed).
#
# Agentation is PolyForm Shield 1.0.0, source-available. This installs it as YOUR project's own dev
# dependency (npm fetches it at your direction); the kit vendors none of its code.
#
# Usage: scripts/annotate-setup.sh [--target DIR] [--framework next|vite|react-router] [--dry-run]
set -euo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v jq   >/dev/null 2>&1 || { echo "✗ jq is required."   >&2; exit 1; }
command -v perl >/dev/null 2>&1 || { echo "✗ perl is required." >&2; exit 1; }

TARGET="$PWD"; FRAMEWORK_OVERRIDE=""; DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)    TARGET="$2"; shift 2 ;;
    --framework) FRAMEWORK_OVERRIDE="$2"; shift 2 ;;
    --dry-run)   DRY_RUN=1; shift ;;
    -h|--help)   sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "✗ unknown flag: $1" >&2; exit 1 ;;
  esac
done
TARGET="$(cd "$TARGET" && pwd)"

# shellcheck source=/dev/null
source "$KIT_ROOT/scripts/lib/react-detect.sh"
react_detect "$TARGET"
[[ -n "$FRAMEWORK_OVERRIDE" ]] && REACT_FRAMEWORK="$FRAMEWORK_OVERRIDE"

if [[ "$REACT_DETECTED" != "true" ]]; then
  echo "✗ No React app detected in $TARGET (no 'react' in package.json)." >&2
  echo "  /kit-annotate targets React apps (Next.js, Vite, React Router). Skipping." >&2
  exit 2
fi

CFG="$TARGET/.claude/kit.config.json"
WING=""; MEMORY_BOOL="false"; PROJECT_NAME="$(basename "$TARGET")"; HTTP_PORT=4747
if [[ -f "$CFG" ]]; then
  WING="$(jq -r '.memory.wing // .project.slug // ""' "$CFG" 2>/dev/null || echo "")"
  MEMORY_BOOL="$(jq -r '.memory.enabled // false'      "$CFG" 2>/dev/null || echo false)"
  PROJECT_NAME="$(jq -r '.project.name // ""'          "$CFG" 2>/dev/null || echo "$PROJECT_NAME")"
  HTTP_PORT="$(jq -r '.annotate.mcp.httpPort // 4747'  "$CFG" 2>/dev/null || echo 4747)"
fi
[[ -z "$WING" || "$WING" == "null" ]] && WING="$(basename "$TARGET" | tr '[:upper:]' '[:lower:]')"
[[ -z "$HTTP_PORT" || "$HTTP_PORT" == "null" ]] && HTTP_PORT=4747

case "$REACT_PKG_MANAGER" in
  pnpm) INSTALL_CMD="pnpm add -D agentation" ;;
  yarn) INSTALL_CMD="yarn add -D agentation" ;;
  bun)  INSTALL_CMD="bun add -d agentation"  ;;
  *)    INSTALL_CMD="npm install -D agentation" ;;
esac
MCP_ADD_CMD='claude mcp add agentation -- npx -y agentation-mcp server'
ENDPOINT="http://localhost:${HTTP_PORT}"

# Dev gate differs by framework: Next reads NODE_ENV; Vite/RR (Vite-based) use import.meta.env.DEV.
case "$REACT_FRAMEWORK" in
  next) GATE='process.env.NODE_ENV === "development"' ;;
  *)    GATE='import.meta.env.DEV' ;;
esac
# The `endpoint` prop is REQUIRED. Without it the toolbar boots `disconnected`, writes only to the
# browser's localStorage, and annotations never reach the MCP receiver on :$HTTP_PORT — so Claude
# sees 0 sessions even while the user is annotating (the bug behind issue #157). Wire it everywhere.
SNIPPET="import { Agentation } from \"agentation\";
// …then, inside your root component's returned JSX, alongside the app:
{ ${GATE} && <Agentation endpoint=\"${ENDPOINT}\" /> }"

emit_rule() {  # resolve <!-- IF:FLAG --> blocks + {{VARS}} exactly like scripts/init.sh
  local src="$1" dest="$2"
  mkdir -p "$(dirname "$dest")"
  KIT_FLAGS_ON="$([[ "$MEMORY_BOOL" == "true" ]] && echo MEMORY || true)" \
  WING="$WING" PROJECT_NAME="$PROJECT_NAME" \
  perl -0777 -pe '
    my %on = map { $_=>1 } grep { length } split /,/, ($ENV{KIT_FLAGS_ON}//"");
    1 while s{<!-- IF:(\w+) -->(.*?)<!-- /IF:\1 -->}{ $on{$1} ? $2 : "" }gse;
    s/\{\{(\w+)\}\}/ exists $ENV{$1} ? $ENV{$1} : "{{$1}}" /ge;
  ' "$src" > "$dest"
}

if [[ $DRY_RUN -eq 1 ]]; then
  echo "→ DRY RUN — /kit-annotate setup plan for $TARGET"
  echo ""
  echo "  React        : yes (v${REACT_VERSION:-?})"
  echo "  Framework    : $REACT_FRAMEWORK"
  echo "  Entry file   : ${REACT_ENTRY_FILE:-"(not auto-found — the skill will ask)"}"
  echo "  Pkg manager  : $REACT_PKG_MANAGER"
  echo "  Memory/wing  : $MEMORY_BOOL / $WING"
  echo ""
  echo "  Would:"
  echo "    1. $INSTALL_CMD"
  echo "    2. $MCP_ADD_CMD"
  echo "         # Agentation's MCP: HTTP :4747 (browser toolbar → store) + MCP stdio (→ Claude)"
  echo "    3. write .claude/rules/react-annotate.md   (memory block: $MEMORY_BOOL)"
  echo "    4. merge .annotate into .claude/kit.config.json"
  echo "    5. (skill applies, with your OK) wire the dev-only toolbar into ${REACT_ENTRY_FILE:-<entry>}:"
  printf '%s\n' "$SNIPPET" | sed 's/^/           /'
  echo ""
  echo "Re-run without --dry-run to apply steps 1–4."
  exit 0
fi

echo "→ Installing agentation (dev dependency, $REACT_PKG_MANAGER)…"
( cd "$TARGET" && eval "$INSTALL_CMD" )

if claude mcp list 2>/dev/null | grep -qi 'agentation'; then
  echo "  ✓ agentation MCP already registered for Claude"
else
  echo "→ Registering the agentation MCP for Claude…"
  ( cd "$TARGET" && eval "$MCP_ADD_CMD" ) \
    || echo "  ⚠ could not auto-register — run it yourself: $MCP_ADD_CMD"
fi

emit_rule "$KIT_ROOT/templates/rules/react-annotate.md" "$TARGET/.claude/rules/react-annotate.md"
echo "  ✓ .claude/rules/react-annotate.md"

if [[ -f "$CFG" ]]; then
  tmp="$(mktemp)"
  jq --arg fw "$REACT_FRAMEWORK" --arg ver "$REACT_VERSION" --arg entry "$REACT_ENTRY_FILE" \
     --argjson port "$HTTP_PORT" \
     '.annotate = {
        enabled: true,
        backend: "agentation",
        framework: $fw,
        reactVersion: $ver,
        entryFile: $entry,
        package: "agentation",
        mcp: { name: "agentation", server: "agentation-mcp", httpPort: $port }
      }' "$CFG" > "$tmp" && mv "$tmp" "$CFG"
  echo "  ✓ .claude/kit.config.json (.annotate)"
else
  echo "  ⚠ no .claude/kit.config.json — run /kit-init first to persist annotate config (rule still written if .claude/ exists)"
fi

echo ""
echo "✓ Agentation wired for Claude — framework: $REACT_FRAMEWORK"
echo ""
echo "Next:"
echo "  • Add the dev-only toolbar to ${REACT_ENTRY_FILE:-your app entry} — keep the endpoint prop:"
printf '%s\n' "$SNIPPET" | sed 's/^/      /'
echo "  • Restart Claude Code so it loads the agentation MCP."
echo "  • Start your dev server, then verify:  npx agentation-mcp doctor"
echo "  • Preflight: with the toolbar open + a note left, the receiver on :$HTTP_PORT should list a"
echo "    session. Connected but 0 sessions ⇒ the endpoint prop is missing or the tab is stale."
exit 0
