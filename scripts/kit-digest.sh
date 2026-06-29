#!/usr/bin/env bash
# kit-digest.sh — pre-digest long inputs (transcripts, CI logs, big files, YouTube URLs)
# with the LOCAL model (scripts/lib/kit-local.sh + mlx_lm.server) so the Claude session
# reads a <=1500-token digest + a pointer to the original instead of the full content.
#
# Usage:
#   ./scripts/kit-digest.sh <path|url> [--focus "<topic>"] [--lang es|en]
#
# Exit codes: 0 digest printed · 2 local server down (caller falls back to reading the
# original directly) · 1 input/usage error.
#
# Chunking: inputs are split into ~2500-word chunks (map), each digested locally, then
# merged in a final reduce pass when there is more than one chunk.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Plugin-direct: stay in the caller's CWD so the project's .claude/kit.config.json
# (.local model/port) is read; the helper + inputs resolve by absolute path.

# shellcheck source=lib/kit-local.sh
source "$SCRIPT_DIR/lib/kit-local.sh"

INPUT="${1:-}"
FOCUS=""
LANG_OUT="es"
shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --focus) FOCUS="$2"; shift 2 ;;
    --lang)  LANG_OUT="$2"; shift 2 ;;
    *) echo "kit-digest: unknown flag $1" >&2; exit 1 ;;
  esac
done

[[ -z "$INPUT" ]] && { echo "usage: kit-digest.sh <path|url> [--focus \"<topic>\"] [--lang es|en]" >&2; exit 1; }

if ! kit_local_alive; then
  echo "kit-digest: local server down (mlx_lm.server :${KIT_LOCAL_PORT}) — read the original directly instead." >&2
  echo "  start it: mlx_lm.server --model ${KIT_LOCAL_MODEL} --port ${KIT_LOCAL_PORT}" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Acquire text
# ---------------------------------------------------------------------------
WORK="$(mktemp -d /tmp/kit-digest.XXXXXX)" || exit 1
trap 'rm -rf "$WORK"' EXIT
TEXT="$WORK/input.txt"
SOURCE_DESC="$INPUT"

vtt_to_text() {  # stdin: VTT -> stdout: deduped plain text
  python3 -c '
import re, sys
out, prev = [], ""
for l in sys.stdin:
    l = l.strip()
    if not l or "-->" in l or l.startswith(("WEBVTT", "Kind:", "Language:")) or re.match(r"^\d+$", l):
        continue
    l = re.sub(r"<[^>]+>", "", l)
    if l != prev:
        out.append(l); prev = l
print(re.sub(r"\s+", " ", " ".join(out)))'
}

if [[ "$INPUT" =~ ^https?://(www\.)?(youtube\.com|youtu\.be)/ ]]; then
  command -v yt-dlp >/dev/null 2>&1 || { echo "kit-digest: yt-dlp required for YouTube URLs (brew install yt-dlp)" >&2; exit 1; }
  TITLE="$(yt-dlp --skip-download --print '%(title)s' "$INPUT" 2>/dev/null | head -1 || true)"
  SOURCE_DESC="${TITLE:-$INPUT} ($INPUT)"
  yt-dlp --skip-download --write-auto-subs --write-subs --sub-langs "en.*,es.*" --sub-format vtt \
    -o "$WORK/yt" "$INPUT" >/dev/null 2>&1 || true
  VTT="$(ls "$WORK"/yt*.vtt 2>/dev/null | head -1 || true)"
  [[ -z "$VTT" ]] && { echo "kit-digest: no subtitles found for $INPUT" >&2; exit 1; }
  vtt_to_text < "$VTT" > "$TEXT"
elif [[ "$INPUT" =~ ^https?:// ]]; then
  curl -sfL -m 30 "$INPUT" 2>/dev/null \
    | perl -0pe 's/<script\b.*?<\/script>//gs; s/<style\b.*?<\/style>//gs; s/<[^>]+>/ /gs' \
    | tr -s ' \t\n' ' ' > "$TEXT" || { echo "kit-digest: fetch failed: $INPUT" >&2; exit 1; }
else
  [[ -f "$INPUT" ]] || { echo "kit-digest: file not found: $INPUT" >&2; exit 1; }
  case "$INPUT" in
    *.vtt) vtt_to_text < "$INPUT" > "$TEXT" ;;
    *)     cat "$INPUT" > "$TEXT" ;;
  esac
fi

WORDS=$(wc -w < "$TEXT" | tr -d ' ')
[[ "${WORDS:-0}" -eq 0 ]] && { echo "kit-digest: empty input" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Map (digest per ~2500-word chunk) -> reduce (merge)
# ---------------------------------------------------------------------------
CHUNK_WORDS=2500
if [[ "$LANG_OUT" == "en" ]]; then
  SYS_MAP="You summarize for an engineering audience. Extract the key points, decisions, numbers and names from this fragment as tight bullets. No intro, no closing."
  SYS_REDUCE="Merge these partial digests into ONE digest of at most 1500 tokens: tight bullets grouped by theme, keep concrete numbers/names/refs. No intro, no closing."
else
  SYS_MAP="Resumes para una audiencia de ingenieria. Extrae los puntos clave, decisiones, numeros y nombres de este fragmento en bullets apretados. Sin intro ni cierre."
  SYS_REDUCE="Fusiona estos digests parciales en UN digest de maximo 1500 tokens: bullets apretados agrupados por tema, conserva numeros/nombres/refs concretos. Sin intro ni cierre."
fi
[[ -n "$FOCUS" ]] && SYS_MAP="$SYS_MAP Prioriza todo lo relacionado con: $FOCUS."

# One chunk per line, CHUNK_WORDS words each (awk: xargs would choke on quotes).
awk -v n="$CHUNK_WORDS" '{for(i=1;i<=NF;i++){printf "%s%s",$i,(++c%n==0?"\n":" ")}}END{if(c%n!=0)print ""}' \
  "$TEXT" > "$WORK/wrapped.txt"
split -l 1 "$WORK/wrapped.txt" "$WORK/chunk." 2>/dev/null

PARTS=()
for c in "$WORK"/chunk.*; do
  [[ -s "$c" ]] || continue
  part="$(kit_local_chat "$SYS_MAP" "$(cat "$c")" 700)" || { echo "kit-digest: local chat failed mid-run" >&2; exit 2; }
  PARTS+=("$part")
done

if [[ ${#PARTS[@]} -eq 1 ]]; then
  DIGEST="${PARTS[0]}"
else
  ALL="$(printf '%s\n\n' "${PARTS[@]}")"
  DIGEST="$(kit_local_chat "$SYS_REDUCE" "$ALL" 1500)" || DIGEST="$ALL"
fi

echo "# Digest (local: $(kit_local_model_tag)) — $SOURCE_DESC"
echo
printf '%s\n' "$DIGEST"
echo
echo "---"
echo "Original: $INPUT ($WORDS palabras, ${#PARTS[@]} chunk(s)) — para deep-dive selectivo, lee el original."
