#!/usr/bin/env bash
# kit-lib.sh — the helper catalog (Effort 220 · #222). `cckit commands` lists the VERBS; nothing
# listed the LIBRARY those verbs are built from, so a helper like pr-evidence.sh — which exists
# precisely to attach gate evidence to a PR — was invisible unless you `ls scripts/lib/`, and an
# agent asked to post evidence wrote it from scratch. This verb makes the library discoverable.
#
# One row per helper in `scripts/lib`, all four facts a caller needs before sourcing it:
#   file      the basename to source
#   errors    its declared failure contract (`# errors:`, CONTRIBUTING) — propagates or swallows
#   functions its PUBLIC functions (`_`-prefixed names are private by convention, so they are cut)
#   purpose   the file's own header sentence — derived, never invented
#
#   cckit lib                      the helper catalog as a markdown table
#   cckit lib --llm                TOON rows {file,errors,functions,purpose} (JSON fallback)
#   cckit lib --all                include the *-test.sh runners (excluded by default)
#   cckit lib --reasons            every file's failure reason, not only the `mixed` ones
#   cckit lib --root <dir>         catalog <dir>'s library instead of the resolved one
#
# Filesystem-only — no network, no gh; jq only for --llm (TOON/JSON). Runs in any project cckit is
# installed in: it catalogs that project's own scripts/lib when it has one, otherwise the cckit
# install the verb is running from (which is the library the caller can actually source).
#
# All parsing lives in pure per-file helpers (kit_lib_purpose / _functions / _errors) so the test
# exercises them against fixture files in a temp dir — no repo scanning, no network.
# errors: best-effort — a file with no `# errors:` header is reported as unknown, never fatal

# ── pure parsers: one file in, one fact out ────────────────────────────────────────────────────

# _kl_clean <text> — make a value safe for a TSV row AND a markdown table cell, then cap it so a
# row stays scannable. A tab would split a field; a pipe would open a phantom table column, so it
# becomes a slash.
_kl_clean() {
  local t
  t="$(printf '%s' "$1" | tr '\t|' ' /' | sed 's/[[:space:]]*$//')"
  if [ "${#t}" -gt 108 ]; then
    t="${t:0:108}"
    case "$t" in *' '*) t="${t% *}" ;; esac   # cut back to a word boundary
    t="${t}…"                                 # braces required: a bare $t… is a name under `set -u`
  fi
  printf '%s' "$t"
}

# _kl_sentence <text> — the first sentence, when the text has one. A lib header's opening line is
# often "<claim>. <elaboration…>"; the claim alone is the one-liner the catalog wants, and it beats
# a mid-word truncation. Refuses a suspiciously short cut (an abbreviation, not a sentence end).
_kl_sentence() {
  local t="$1" first
  case "$t" in
    *'. '*)
      first="${t%%'. '*}."
      if [ "${#first}" -ge 24 ]; then printf '%s' "$first"; return 0; fi ;;
  esac
  printf '%s' "$t"
}

# kit_lib_purpose <file> — the file's one-line purpose, taken from its OWN header comment: the
# first real comment line (shebang and `# shellcheck` directives skipped), with the customary
# "<name>.sh — " self-mention stripped and only the first sentence kept, so the cell reads as a
# sentence. Never invents one; a file with no header comment reports `unknown`. Honest limit: a
# header whose opening line has no sentence end is shown truncated with an ellipsis — read the file.
kit_lib_purpose() {
  local f="$1" t
  [ -f "$f" ] || { printf '%s' "unknown"; return 0; }
  t="$(sed -n '1,25p' "$f" | sed -n '/^#!/d; /^#[[:space:]]*shellcheck/d; /^#/p' | head -1)"
  [ -n "$t" ] || { printf '%s' "unknown"; return 0; }
  t="${t#\#}"
  # trim leading blanks without a subprocess (portable across bash 3.2 + zsh)
  while :; do
    case "$t" in
      ' '*)  t="${t# }" ;;
      '	'*) t="${t#	}" ;;
      *) break ;;
    esac
  done
  case "$t" in
    *'.sh — '*) t="${t#*'.sh — '}" ;;
    *'.sh - '*) t="${t#*'.sh - '}" ;;
    *'.sh: '*)  t="${t#*'.sh: '}" ;;
  esac
  [ -n "$t" ] || t="unknown"
  _kl_clean "$(_kl_sentence "$t")"
}

# kit_lib_functions <file> — the PUBLIC function names, space-separated, sorted. The house
# convention is that `_`-prefixed functions are private, so an initial letter is required; the
# column-0 anchor also drops helpers defined INSIDE another function (always an implementation
# detail). Empty output means the file exposes no callable surface (a runner, or config only).
kit_lib_functions() {
  local f="$1"
  [ -f "$f" ] || return 0
  {
    grep -E '^[A-Za-z][A-Za-z0-9_:.-]*[[:space:]]*\(\)' "$f" 2>/dev/null
    grep -E '^function[[:space:]]+[A-Za-z][A-Za-z0-9_:.-]*' "$f" 2>/dev/null \
      | sed 's/^function[[:space:]]*//'
  } | sed 's/[[:space:]]*(.*//; s/[[:space:]].*//' | grep -E '^[A-Za-z]' | sort -u \
    | tr '\n' ' ' | sed 's/ *$//'
}

# _kl_header <file> — the file's LEADING comment block: the shebang skipped, blank lines skipped,
# every comment line up to the first line of actual code. A fixed line window cannot do this job —
# 25 lines is too tight for pr-evidence.sh and kit-task-ops.sh, whose headers run past it, and any
# larger number is equally arbitrary. Bounding by structure instead means a later `# errors:` line
# in the body (a comment quoting this convention, say) is never read as the declaration.
_kl_header() {
  [ -f "$1" ] || return 0
  awk 'NR==1 && /^#!/ {next} /^[[:space:]]*#/ {print; next} /^[[:space:]]*$/ {next} {exit}' "$1" 2>/dev/null
}

# kit_lib_errors <file> — the declared failure contract: pure | strict | best-effort | mixed, or
# `unknown` when the file carries no `# errors:` header (a file that predates #223, or a host
# project's own lib). Same parse as scripts/lib/errors-header-test.sh, which enforces it.
kit_lib_errors() {
  local v=""
  # Read the header block only (see _kl_header) so a body comment is never taken for the contract.
  [ -f "$1" ] && v="$(_kl_header "$1" | sed -n 's/^#[[:space:]]*errors:[[:space:]]*\([a-z-]*\).*/\1/p' | head -1)"
  [ -n "$v" ] || v="unknown"
  printf '%s' "$v"
}

# kit_lib_errors_reason <file> — the required reason after the em dash, or empty. For a `mixed`
# file this is the ONLY thing saying which half propagates, so the catalog always shows it there.
kit_lib_errors_reason() {
  local line=""
  [ -f "$1" ] && line="$(_kl_header "$1" | sed -n 's/^#[[:space:]]*errors:[[:space:]]*//p' | head -1)"
  case "$line" in
    *'— '*) printf '%s' "${line#*'— '}" ;;
    *) printf '' ;;
  esac
}

# ── the catalog ───────────────────────────────────────────────────────────────────────────────

# kit_lib_files <dir> [all] — one helper path per line, sorted. `*-test.sh` files are EXCLUDED by
# default: they are runners, not a callable library — their functions are local assertion helpers
# (`t`, `eq`, `has`) that no caller should source, and every one of them declares the same
# `strict — a test runner` contract, so listing them buries the ~40 real helpers. `all=1` includes
# them (the count is surfaced in the human footer either way, so nothing is silently hidden).
# `find` rather than a glob: an unmatched glob errors under zsh's nomatch and stays literal under
# bash, while `find` handles "no matches" cleanly in both.
kit_lib_files() {
  local dir="$1" all="${2:-0}" f b
  [ -n "$dir" ] && [ -d "$dir" ] || return 0
  find "$dir" -maxdepth 1 -name '*.sh' -type f 2>/dev/null | sort | while IFS= read -r f; do
    b="$(basename "$f")"
    case "$b" in
      *-test.sh) if [ "$all" = "1" ]; then printf '%s\n' "$f"; fi ;;
      *) printf '%s\n' "$f" ;;
    esac
  done
}

# kit_lib_rows <dir> [all] [reasons] — the catalog as TSV: file<TAB>errors<TAB>functions<TAB>purpose.
# One shape feeds both views (markdown table and TOON), so they can never disagree.
kit_lib_rows() {
  local dir="$1" all="${2:-0}" reasons="${3:-0}" f base ev er fn pu
  [ -n "$dir" ] && [ -d "$dir" ] || return 0
  kit_lib_files "$dir" "$all" | while IFS= read -r f; do
    base="$(basename "$f")"
    ev="$(kit_lib_errors "$f")"
    er="$(kit_lib_errors_reason "$f")"
    if [ -n "$er" ] && { [ "$reasons" = "1" ] || [ "$ev" = "mixed" ]; }; then
      ev="$ev — $er"
    fi
    # NOT capped: the function names are the whole point of the catalog — an elided list would
    # hide the very helper a caller came here to find. Purpose and errors are prose, so they cap.
    fn="$(kit_lib_functions "$f")"
    [ -n "$fn" ] || fn="—"
    pu="$(kit_lib_purpose "$f")"
    printf '%s\t%s\t%s\t%s\n' "$base" "$(_kl_clean "$ev")" "$fn" "$pu"
  done
}

# ── which library to catalog ──────────────────────────────────────────────────────────────────

# _kl_project_root — the invoking project's root. Reuses plan-next.sh's `_pn_root` (KIT_CONFIG's
# parent, else $PWD) rather than re-deriving it: one root-inference rule for both introspection
# verbs. Falls back to $PWD if that sibling is unavailable. Note this inherits PLAN_NEXT_ROOT.
_kl_project_root() {
  local here
  if ! command -v _pn_root >/dev/null 2>&1; then
    here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)" || here=""
    if [ -n "$here" ] && [ -f "$here/plan-next.sh" ]; then
      # shellcheck source=/dev/null
      . "$here/plan-next.sh" 2>/dev/null || true
    fi
  fi
  if command -v _pn_root >/dev/null 2>&1; then _pn_root; return 0; fi
  printf '%s' "$PWD"
}

# kit_lib_dir [root] — the directory to catalog, first hit wins:
#   1. $KIT_LIB_DIR            explicit override (tests point it at a fixture dir)
#   2. <root>/scripts/lib      an explicit --root (then .claude/scripts/lib, then <root> itself)
#   3. <project>/scripts/lib   the invoking project's own library, when it has one
#   4. this file's own dir     the cckit install the verb is running FROM — in a host project with
#                              no library of its own, that IS the library `cckit` can source.
# rc 1 (and no output) when nothing resolves, so the caller shows an empty state instead of crashing.
kit_lib_dir() {
  local root="${1:-}" d here
  if [ -n "${KIT_LIB_DIR:-}" ] && [ -d "${KIT_LIB_DIR:-}" ]; then printf '%s' "$KIT_LIB_DIR"; return 0; fi
  if [ -n "$root" ]; then
    for d in "$root/scripts/lib" "$root/.claude/scripts/lib" "$root"; do
      [ -d "$d" ] && { printf '%s' "$d"; return 0; }
    done
    return 1
  fi
  root="$(_kl_project_root)"
  for d in "$root/scripts/lib" "$root/.claude/scripts/lib"; do
    [ -d "$d" ] && { printf '%s' "$d"; return 0; }
  done
  here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)" || here=""
  if [ -n "$here" ] && [ -d "$here" ]; then printf '%s' "$here"; return 0; fi
  return 1
}

# ── the verb ──────────────────────────────────────────────────────────────────────────────────

# _kl_usage — the usage block, read back from this file's own header (one source of truth).
_kl_usage() { sed -n 's/^#   \(cckit lib.*\)$/\1/p' "${BASH_SOURCE[0]:-$0}"; }

# _kl_err — structured error for --llm mode (mirrors the other verbs' failure shape).
_kl_err() { printf '{"error":"lib: %s"}\n' "$1"; }

# kit_lib — the verb body. Human markdown by default; TOON/JSON under --llm.
kit_lib() {
  local out="${CCKIT_OUTPUT:-human}" root="" all=0 reasons=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --llm|--output=json) out="json"; shift ;;
      --all)     all=1; shift ;;
      --reasons) reasons=1; shift ;;
      --root)    # Validate BEFORE shifting: `shift 2` on a single remaining argument aborts bash
                 # with "shift count out of range" instead of the parser's own error.
                 [ "$#" -ge 2 ] || { if [ "$out" = "json" ]; then _kl_err "--root needs a directory"; else echo "lib: --root needs a directory" >&2; fi; return 2; }
                 root="$2"; shift 2 ;;
      --root=*)  root="${1#*=}"; shift ;;
      -h|--help) _kl_usage; return 0 ;;
      *) if [ "$out" = "json" ]; then _kl_err "unknown arg '$1'"; else echo "lib: unknown arg '$1'" >&2; fi
         return 2 ;;
    esac
  done

  # --llm needs jq for valid TOON/JSON — emit a structured error rather than malformed output.
  if [ "$out" = "json" ] && ! command -v jq >/dev/null 2>&1; then
    _kl_err "jq is required for --llm output"; return 1
  fi

  local dir rows n runners
  dir="$(kit_lib_dir "$root")" || dir=""
  rows=""; n=0; runners=0
  if [ -n "$dir" ]; then
    rows="$(kit_lib_rows "$dir" "$all" "$reasons")"
    n="$(printf '%s' "$rows" | grep -c . || true)"
    runners="$(kit_lib_files "$dir" 1 | grep -c -- '-test\.sh$' || true)"
  fi

  local here; here="$(dirname "${BASH_SOURCE[0]:-$0}")"

  if [ "$out" = "json" ]; then
    # TOON rows {file,errors,functions,purpose}. An empty catalog is a legitimate answer (a host
    # project with no library), so it emits [] rather than an error.
    local json
    json="$(printf '%s\n' "$rows" | jq -R -s '[ split("\n")[] | select(length>0) | split("\t")
              | {file:.[0], errors:.[1], functions:.[2], purpose:.[3]} ]')"
    # shellcheck source=/dev/null
    . "$here/toon.sh"
    printf '%s' "$json" | toon_encode
    return 0
  fi

  # human: a markdown table through the rendering seam (#82), same as plan-next.
  # shellcheck source=/dev/null
  . "$here/render.sh" 2>/dev/null || true
  _kl_human() {
    printf '# Helper library — %s helper(s)\n\n' "$n"
    if [ -z "$dir" ]; then
      printf '> No `scripts/lib` found here and cckit could not locate its own — nothing to catalog.\n'
      return 0
    fi
    printf '`%s`\n\n' "$dir"
    if [ "$n" -eq 0 ]; then
      printf '> That directory holds no `.sh` helpers to catalog'
      if [ "$all" != "1" ] && [ "$runners" -gt 0 ]; then
        printf ' (its %s `*-test.sh` runner(s) are excluded; pass `--all`)' "$runners"
      fi
      printf '.\n'
      return 0
    fi
    printf '| file | errors | public functions | purpose |\n| --- | --- | --- | --- |\n'
    printf '%s\n' "$rows" | awk -F'\t' 'NF>=4 { printf "| `%s` | %s | %s | %s |\n", $1, $2, $3, $4 }'
    printf '\n## How to read this\n\n'
    printf -- '- **errors** is the file'"'"'s declared failure contract: `pure`, `strict`, `best-effort` or\n'
    printf -- '  `mixed`. A caller that mixes a `strict` helper with a `best-effort` one inherits the weaker\n'
    printf -- '  behaviour, so check this before composing two. `mixed` rows carry their reason because it is\n'
    printf -- '  the only thing saying which half propagates; `--reasons` shows every reason.\n'
    printf -- '- **public functions** excludes `_`-prefixed names (private by convention).\n'
    printf -- '- `unknown` means the file carries no `# errors:` header yet — the catalog reports it and\n'
    printf -- '  moves on rather than failing.\n'
    if [ "$all" = "1" ]; then
      printf -- '- `--all` is on, so the %s `*-test.sh` runner(s) are included.\n' "$runners"
    else
      printf -- '- %s `*-test.sh` runner(s) are excluded — they are test entry points, not a library.\n' "$runners"
      printf -- '  Pass `--all` to include them.\n'
    fi
    printf '\n## Use one\n\n```bash\nsource %s/<file>\n```\n' "$dir"
  }
  if command -v cckit_render >/dev/null 2>&1; then _kl_human | cckit_render; else _kl_human; fi
}
