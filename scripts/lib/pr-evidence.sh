#!/usr/bin/env bash
# pr-evidence.sh — attach evidence (build/typecheck logs, screenshots) to a PR as a comment.
#
# A PR should carry the proof that its gates passed (the log, the rendered screen), not just a
# prose claim — the "evidence" half of a no-mistakes agentic workflow. This is the sourceable
# helper the kit-effort-pr / kit-task-pr flow calls after the PR is open.
#
# Source it:  source scripts/lib/pr-evidence.sh
#
# Functions:
#   pr_attach_evidence <pr-number> <evidence-file> [caption]   post the evidence into the PR
#   pr_evidence_usage                                          print how kit-effort-pr should call it
#
# Best-effort by contract: a missing gh, missing args, or missing file warns + returns 0 so it
# NEVER hard-fails the caller. Callers should still append `|| true` for set -e safety.
#
# Requires: gh, jq not needed; uses git/coreutils. bash 3.2 compatible.
#
# Env:
#   PR_EVIDENCE_REPO        target repo in OWNER/REPO form; empty (default) = let gh resolve it
#                           from the current repo (omits --repo)
#   KIT_EVIDENCE_URL_BASE   host base for images — set it and an image embeds as ![caption](URL)
#   KIT_EVIDENCE_MAX_BYTES  inline truncation cap for text/log files (default 60000)

PR_EVIDENCE_REPO="${PR_EVIDENCE_REPO:-}"

# True when the file extension is a raster/vector image GitHub would render if uploaded.
_pr_evidence_is_image() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    *.png|*.jpg|*.jpeg|*.gif|*.webp|*.svg|*.bmp|*.tif|*.tiff) return 0 ;;
    *) return 1 ;;
  esac
}

# Map a file extension to a fenced-code language hint.
_pr_evidence_lang() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    *.json)            echo json ;;
    *.diff|*.patch)    echo diff ;;
    *.md|*.markdown)   echo "" ;;
    *.sh|*.bash)       echo bash ;;
    *.ts|*.tsx)        echo ts ;;
    *.js|*.jsx)        echo js ;;
    *)                 echo text ;;
  esac
}

# Echo a backtick fence (>= 3) longer than any backtick run in the file, so log content
# that itself contains ``` cannot break out of the code block.
_pr_evidence_fence() {
  local file="$1" longest n
  longest=$(grep -oE '`+' "$file" 2>/dev/null | awk '{ if (length($0) > m) m = length($0) } END { print m+0 }')
  n=3
  [[ "${longest:-0}" -ge 3 ]] && n=$((longest + 1))
  printf '%*s' "$n" '' | tr ' ' '`'
}

# Build the comment body for a text/log evidence file (inlined, fenced, truncation-aware).
_pr_evidence_text_body() {
  local caption="$1" file="$2"
  local max="${KIT_EVIDENCE_MAX_BYTES:-60000}"
  local lang fence size
  lang="$(_pr_evidence_lang "$file")"
  fence="$(_pr_evidence_fence "$file")"
  size=$(wc -c <"$file" 2>/dev/null | tr -d '[:space:]'); size="${size:-0}"

  printf '## Evidence — %s\n\n' "$caption"
  printf '_Source: `%s`_\n\n' "$(basename "$file")"
  printf '%s%s\n' "$fence" "$lang"
  if [[ "$size" -gt "$max" ]]; then
    head -c "$max" "$file"
    printf '\n%s\n\n' "$fence"
    printf '_…truncated — showing the first %s of %s bytes. Full file: `%s`._\n' "$max" "$size" "$file"
  else
    cat "$file"
    printf '\n%s\n' "$fence"
  fi
}

# Build the comment body for an image evidence file.
# HONEST about the limitation: GitHub has no clean REST/CLI endpoint to upload a binary to a
# comment (uploads go through an undocumented, web-only multipart endpoint that gh does not
# expose). So an image is REFERENCED by local path + instructions; only when KIT_EVIDENCE_URL_BASE
# points at a host that already serves the file do we embed it with ![caption](URL).
_pr_evidence_image_body() {
  local caption="$1" abs="$2" base="$3"
  printf '## Evidence — %s\n\n' "$caption"
  if [[ -n "${KIT_EVIDENCE_URL_BASE:-}" ]]; then
    printf '![%s](%s/%s)\n\n' "$caption" "${KIT_EVIDENCE_URL_BASE%/}" "$base"
    printf '_Embedded via `KIT_EVIDENCE_URL_BASE`. A broken image means the file is not hosted there yet._\n\n'
  fi
  printf '> Image evidence is **referenced, not uploaded**: GitHub exposes no clean REST/CLI\n'
  printf '> endpoint to attach a binary to a comment (the upload path is an undocumented,\n'
  printf '> web-only multipart endpoint that `gh` does not surface). To inline this image,\n'
  printf '> drag-and-drop the file into the PR comment box in the browser, or host it and set\n'
  printf '> `KIT_EVIDENCE_URL_BASE` so this helper embeds it.\n\n'
  printf 'Local file: `%s`\n' "$abs"
}

# pr_attach_evidence <pr-number> <evidence-file> [caption]
# Post the evidence into the PR as a comment. Text/log files inline in a fenced block; images are
# referenced (see _pr_evidence_image_body). Caption defaults to the file basename.
pr_attach_evidence() {
  local pr="${1:-}" file="${2:-}" caption="${3:-}"

  if [[ -z "$pr" || -z "$file" ]]; then
    echo "pr_attach_evidence: need <pr-number> <evidence-file> [caption] — skipping" >&2
    pr_evidence_usage >&2
    return 0
  fi
  if ! command -v gh >/dev/null 2>&1; then
    echo "pr_attach_evidence: gh CLI not found — cannot post evidence to PR #$pr (skipping)" >&2
    return 0
  fi
  if [[ ! -f "$file" ]]; then
    echo "pr_attach_evidence: evidence file not found: $file (skipping)" >&2
    return 0
  fi
  [[ -n "$caption" ]] || caption="$(basename "$file")"

  local repo abs tmp
  repo="${PR_EVIDENCE_REPO:-}"
  abs="$(cd "$(dirname "$file")" 2>/dev/null && printf '%s/%s' "$(pwd)" "$(basename "$file")")"
  [[ -n "$abs" ]] || abs="$file"

  tmp="$(mktemp 2>/dev/null)" || { echo "pr_attach_evidence: mktemp failed (skipping)" >&2; return 0; }

  if _pr_evidence_is_image "$file"; then
    _pr_evidence_image_body "$caption" "$abs" "$(basename "$file")" >"$tmp"
  else
    _pr_evidence_text_body "$caption" "$file" >"$tmp"
  fi

  # Omit --repo when PR_EVIDENCE_REPO is empty so gh resolves the repo from the current directory.
  local posted=1
  if [[ -n "$repo" ]]; then
    gh pr comment "$pr" --repo "$repo" --body-file "$tmp" >/dev/null 2>&1 && posted=0
  else
    gh pr comment "$pr" --body-file "$tmp" >/dev/null 2>&1 && posted=0
  fi
  if [[ "$posted" -eq 0 ]]; then
    echo "✓ evidence attached to PR #$pr ($caption)" >&2
    rm -f "$tmp"
    return 0
  fi
  echo "✗ failed to post evidence comment to PR #$pr — body kept at $tmp" >&2
  return 1
}

# pr_evidence_usage — how kit-effort-pr / kit-task-pr should call this helper.
pr_evidence_usage() {
  cat <<'USAGE'
pr-evidence.sh — attach PR evidence (build/typecheck logs, screenshots) as a PR comment.

  source scripts/lib/pr-evidence.sh
  pr_attach_evidence <pr-number> <evidence-file> [caption]

kit-effort-pr should call it AFTER the PR is opened, once per gate artifact:

  pr_num=$(gh pr list --head "$branch" --json number --jq '.[0].number')
  pr_attach_evidence "$pr_num" build.log     "build"                    || true
  pr_attach_evidence "$pr_num" typecheck.log "typecheck"                || true
  pr_attach_evidence "$pr_num" screen.png    "rendered — success state" || true

Text/log files are inlined in an auto-sized fenced block (truncated past
KIT_EVIDENCE_MAX_BYTES, default 60000). Images CANNOT be uploaded via gh/REST, so they
are referenced by local path + instructions; set KIT_EVIDENCE_URL_BASE to a host base
and the helper embeds ![caption](URL) instead.

Env: PR_EVIDENCE_REPO (OWNER/REPO; empty = gh resolves it from the current repo) ·
     KIT_EVIDENCE_URL_BASE · KIT_EVIDENCE_MAX_BYTES (default 60000).
USAGE
}
