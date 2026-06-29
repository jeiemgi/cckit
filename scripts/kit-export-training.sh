#!/usr/bin/env bash
# kit-export-training.sh — OPT-IN export of your Claude Code sessions to redacted training JSONL.
#
# Fine-tuning a local model on your own work only helps if the data leaves the machine clean. This
# handler is the consent gate in front of a dataset builder (chat-datasets/build_dataset.py): it
# lets a builder pick which sessions to export, ALWAYS runs the builder with redaction ON
# (secret/key/email masking is the builder's default — there is deliberately NO --no-redact
# passthrough here), and prints exactly where it wrote plus a reminder that redaction must be
# verified before sharing.
#
# Nothing here is automatic — it runs only when explicitly invoked, and it never uploads anything.
# The output is plain JSONL on disk for the training pipeline; what you do with it is your call.
#
# Run:
#   scripts/kit-export-training.sh [--builder PATH] [--match KEY ...] [--dirs DIR ...]
#                                  [--sessions FILE ...] [--out PATH] [--split FRAC]
#                                  [--final-only] [--drop-narration]
# Selection (pick one; default = the current git project, matched by its slug):
#   --match KEY ...     project-dir name substrings under ~/.claude/projects (e.g. my-app acme)
#   --dirs  DIR ...     explicit ~/.claude/projects/<dir> session directories
#   --sessions FILE ... individual *.jsonl transcript files to export (symlinked into a temp dir)
# Options:
#   --builder PATH      path to build_dataset.py (overrides KIT_DATASET_BUILDER + auto-discovery)
#   --out PATH          output JSONL (default: ~/.claude/exports/<slug>-training.jsonl)
#   --split FRAC        also emit train.jsonl/valid.jsonl with FRAC held out (e.g. 0.1)
#   --final-only        keep only the last assistant message per turn
#   --drop-narration    drop short process-narration openers
# Env:
#   KIT_DATASET_BUILDER  path to build_dataset.py (used when --builder is not given)
#   KIT_PROJECTS_ROOT    sessions root (default: ~/.claude/projects)
#   KIT_ASSUME_YES       skip the final confirm (for batch/CI).
#
# Builder discovery (config-driven, NO hardcoded user path): --builder > KIT_DATASET_BUILDER >
# a sibling `chat-datasets/build_dataset.py` next to the git repo root (then $PWD). If none resolve,
# the script stops and tells you to pass --builder or set KIT_DATASET_BUILDER.
#
# Redaction is ALWAYS on here — the builder masks by default and this script never passes --no-redact.
set -uo pipefail

# ---- locate self + optional shared cli helpers ----------------------------
_kxt_dir="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=/dev/null
[ -f "$_kxt_dir/lib/kit-cli.sh" ] && . "$_kxt_dir/lib/kit-cli.sh"   # provides kit_is_main (optional)

PROJECTS_ROOT="${KIT_PROJECTS_ROOT:-$HOME/.claude/projects}"

# Staged-sessions temp dir, cleaned on exit. Script-global so the EXIT trap can read it
# after _kxt_main returns (a function-local would be out of scope under `set -u`).
_KXT_TMP_SEL=""
_kxt_cleanup() { [ -n "${_KXT_TMP_SEL:-}" ] && rm -rf "$_KXT_TMP_SEL"; return 0; }

# ---- minimal logging ------------------------------------------------------
if [ -t 2 ]; then _AZ=$'\033[38;2;201;122;44m'; _RD=$'\033[38;2;194;87;56m'; _GR=$'\033[38;2;120;160;90m'; _DM=$'\033[2m'; _RS=$'\033[0m'
else _AZ=''; _RD=''; _GR=''; _DM=''; _RS=''; fi
_kxt_say()  { printf '%s->%s %s\n' "$_AZ" "$_RS" "$*" >&2; }
_kxt_warn() { printf '%s!%s %s\n'  "$_RD" "$_RS" "$*" >&2; }
_kxt_err()  { printf '%sx%s %s\n'  "$_RD" "$_RS" "$*" >&2; }
_kxt_die()  { _kxt_err "$*"; exit 1; }

# ---- builder resolution (config-driven, generalized off any one machine) ---
# $1 = explicit --builder value (may be empty). Priority: explicit > env > sibling discovery.
_kxt_resolve_builder() {
  local explicit="${1:-}"
  [ -n "$explicit" ] && { printf '%s\n' "$explicit"; return 0; }
  [ -n "${KIT_DATASET_BUILDER:-}" ] && { printf '%s\n' "$KIT_DATASET_BUILDER"; return 0; }
  local rel="chat-datasets/build_dataset.py" root="" rootp="" base="" cand=""
  root="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$root" ] && rootp="$(dirname "$root")"
  for base in "$rootp" "$PWD" "$(dirname "$PWD")"; do
    [ -n "$base" ] || continue
    cand="$base/$rel"
    [ -f "$cand" ] && { printf '%s\n' "$cand"; return 0; }
  done
  return 1
}

# ---- main (direct execution only; sourcing exposes the functions for tests) ---
_kxt_main() {
  local BUILDER_FLAG="" OUT="" SPLIT="" SLUG="export" BUILDER="" _root=""
  local -a MATCH=() DIRS=() SESSIONS=() EXTRA=() SEL=() SPLIT_ARGS=()
  while [ $# -gt 0 ]; do case "$1" in
    --builder)      BUILDER_FLAG="${2:-}"; shift 2 ;;
    --match)        shift; while [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; do MATCH+=("$1"); shift; done ;;
    --dirs)         shift; while [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; do DIRS+=("$1"); shift; done ;;
    --sessions)     shift; while [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; do SESSIONS+=("$1"); shift; done ;;
    --out)          OUT="${2:-}"; shift 2 ;;
    --split)        SPLIT="${2:-}"; shift 2 ;;
    --final-only)   EXTRA+=(--final-only); shift ;;
    --drop-narration) EXTRA+=(--drop-narration); shift ;;
    -h|--help)      sed -n '13,33p' "$0" | sed 's/^# \{0,1\}//'; return 0 ;;
    *) _kxt_die "unknown flag: $1" ;;
  esac; done

  # ---- preflight ----------------------------------------------------------
  command -v python3 >/dev/null 2>&1 || _kxt_die "python3 is required."
  BUILDER="$(_kxt_resolve_builder "$BUILDER_FLAG")" || _kxt_die \
    "dataset builder not found — pass --builder PATH or set KIT_DATASET_BUILDER (looked for chat-datasets/build_dataset.py beside the repo root)."
  [ -f "$BUILDER" ] || _kxt_die "dataset builder not found: $BUILDER"

  # ---- resolve a default selection from the current git project -----------
  if [ ${#MATCH[@]} -eq 0 ] && [ ${#DIRS[@]} -eq 0 ] && [ ${#SESSIONS[@]} -eq 0 ]; then
    _root="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || true)"
    [ -n "$_root" ] || _kxt_die "no selection given and not inside a git repo — pass --match/--dirs/--sessions."
    SLUG="$(basename "$_root" | tr '[:upper:]' '[:lower:]')"
    MATCH=("$SLUG")
    _kxt_say "no selection given — defaulting to the current project (match: $SLUG)"
  elif [ ${#MATCH[@]} -gt 0 ]; then
    SLUG="$(printf '%s' "${MATCH[0]}" | tr '[:upper:]' '[:lower:]')"
  fi

  # ---- default output path ------------------------------------------------
  if [ -z "$OUT" ]; then
    mkdir -p "$HOME/.claude/exports"
    OUT="$HOME/.claude/exports/${SLUG}-training.jsonl"
  fi
  mkdir -p "$(dirname "$OUT")"

  # ---- build the selection args for the builder ---------------------------
  # --sessions: stage the chosen transcript files into a temp dir and pass via --dirs,
  # since build_dataset.py selects at directory granularity.
  local f=""
  trap _kxt_cleanup EXIT

  if [ ${#SESSIONS[@]} -gt 0 ]; then
    _KXT_TMP_SEL="$(mktemp -d)"
    for f in "${SESSIONS[@]}"; do
      [ -f "$f" ] || _kxt_die "session file not found: $f"
      ln -s "$(cd "$(dirname "$f")" && pwd)/$(basename "$f")" "$_KXT_TMP_SEL/$(basename "$f")"
    done
    SEL=(--dirs "$_KXT_TMP_SEL")
    _kxt_say "exporting ${#SESSIONS[@]} selected session file(s)"
  elif [ ${#DIRS[@]} -gt 0 ]; then
    SEL=(--dirs "${DIRS[@]}")
    _kxt_say "exporting from ${#DIRS[@]} session director(ies)"
  else
    SEL=(--match "${MATCH[@]}")
    _kxt_say "exporting sessions matching: ${MATCH[*]}"
  fi

  [ -d "$PROJECTS_ROOT" ] || _kxt_warn "sessions root $PROJECTS_ROOT not found — the export may be empty."

  # ---- confirm (opt-in) ---------------------------------------------------
  if [ -z "${KIT_ASSUME_YES:-}" ] && [ -t 0 ]; then
    printf '%sExport redacted training JSONL to %s ? [y/N] %s' "$_DM" "$OUT" "$_RS" >&2
    local _c=""; read -r _c < /dev/tty || true
    case "$_c" in y|Y|yes|YES) ;; *) _kxt_die "aborted — nothing was written." ;; esac
  fi

  # ---- run the builder with redaction ON (always) -------------------------
  [ -n "$SPLIT" ] && SPLIT_ARGS=(--split "$SPLIT")
  _kxt_say "running build_dataset.py (redaction ON): $BUILDER"
  python3 "$BUILDER" "${SEL[@]}" --out "$OUT" ${EXTRA[@]+"${EXTRA[@]}"} ${SPLIT_ARGS[@]+"${SPLIT_ARGS[@]}"} \
    || _kxt_die "build_dataset.py failed — nothing trustworthy was written."

  # ---- report -------------------------------------------------------------
  local STATS="${OUT%.jsonl}.stats.json"
  printf '\n' >&2
  _kxt_say "Wrote training data:"
  printf '    %sJSONL:%s %s\n' "$_GR" "$_RS" "$OUT" >&2
  [ -f "$STATS" ] && printf '    %sstats:%s %s\n' "$_GR" "$_RS" "$STATS" >&2
  if [ -n "$SPLIT" ]; then
    printf '    %ssplit:%s %s/train.jsonl + valid.jsonl\n' "$_GR" "$_RS" "$(dirname "$OUT")" >&2
  fi
  printf '\n' >&2
  _kxt_warn "Redaction was applied automatically, but it is NOT a guarantee."
  _kxt_warn "VERIFY the output for any leftover secrets, tokens, private names, or customer data"
  _kxt_warn "BEFORE sharing it or feeding it into the training pipeline."
}

# Run only on direct execution; `source`-ing the file just defines the functions (for tests).
if command -v kit_is_main >/dev/null 2>&1; then
  kit_is_main && _kxt_main "$@"
else
  [ "${BASH_SOURCE[0]:-$0}" = "${0}" ] && _kxt_main "$@"
fi
