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
#   pr_attach_evidence [--strict|--best-effort] <pr-number> <evidence-file> [caption]
#                                                              upsert the evidence into the PR
#   pr_evidence_usage                                          print how kit-effort-pr should call it
#
# UPSERT, not append (#224). Each comment carries an invisible HTML-comment marker keyed on the
# caption — `<!-- cckit:pr-evidence key=<slug> -->` — so a re-run finds this helper's own previous
# comment for THAT caption and EDITs it in place. Two captions on one PR are two comments; the same
# caption twice is one comment, updated. Nothing is ever posted twice by a successful run.
#
# TWO FAILURE MODES, best-effort is the DEFAULT:
#   default        every failure warns on stderr and returns 0, so a failed comment never breaks
#                  the PR flow it is only annotating. Callers may still append `|| true`.
#   --strict, or   every failure returns a distinct non-zero rc. Nothing that could not run is
#   PR_EVIDENCE_STRICT=1
#                  ever reported as a clean result — no `|| true`, no swallowed API error.
# Either way `$PR_EVIDENCE_LAST_RESULT` names the outcome, so even a best-effort caller can tell
# whether the evidence actually landed:
#   created · updated · bad-args · no-gh · no-file · mktemp-failed · lookup-failed · post-failed
#
# Strict exit codes:  2 bad args · 3 gh missing · 4 evidence file missing · 5 mktemp failed ·
#                     6 comment lookup failed · 7 create/edit failed
#
# Requires: gh (its built-in --jq; no external jq). bash 3.2 compatible, zsh-safe.
#
# Env:
#   PR_EVIDENCE_REPO        target repo in OWNER/REPO form; empty (default) = let gh resolve it
#                           from the current repo (uses the {owner}/{repo} placeholders)
#   PR_EVIDENCE_STRICT      1/true/yes/on = strict mode for every call (default 0 = best-effort)
#   KIT_EVIDENCE_URL_BASE   host base for images — set it and an image embeds as ![caption](URL)
#   KIT_EVIDENCE_MAX_BYTES  inline truncation cap for text/log files (default 60000)
# errors: mixed — pr_attach_evidence is best-effort by default (warns, rc 0) and propagates every failure with a distinct rc under --strict / PR_EVIDENCE_STRICT=1; the marker/body builders are pure

PR_EVIDENCE_REPO="${PR_EVIDENCE_REPO:-}"
PR_EVIDENCE_STRICT="${PR_EVIDENCE_STRICT:-0}"
PR_EVIDENCE_LAST_RESULT="${PR_EVIDENCE_LAST_RESULT:-}"

# The marker prefix. STABLE ACROSS VERSIONS by contract: changing it orphans every evidence comment
# already on every open PR, so an older cckit's comments would be appended to instead of edited.
PR_EVIDENCE_MARKER_PREFIX='<!-- cckit:pr-evidence key='

# ── pure: identity ─────────────────────────────────────────────────────────────────────────────

# _pr_evidence_key <caption> — a stable slug identifying ONE evidence artifact.
# Deterministic on the caption alone, so the same gate re-run keys to the same comment. Falls back
# to a checksum when the caption has no [a-z0-9] at all (an emoji-only caption would otherwise slug
# to the empty string and collide with every other such caption).
_pr_evidence_key() {
  local raw="$1" slug
  slug="$(printf '%s' "$raw" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C tr -cs 'a-z0-9' '-')"
  slug="${slug#-}"; slug="${slug%-}"
  slug="$(printf '%s' "$slug" | cut -c1-48)"; slug="${slug%-}"
  if [ -z "$slug" ]; then
    slug="k$(printf '%s' "$raw" | cksum 2>/dev/null | awk '{print $1}')"
    [ "$slug" != "k" ] || slug="evidence"
  fi
  printf '%s' "$slug"
}

# _pr_evidence_marker <caption> — the invisible marker line for that caption.
# An HTML comment: GitHub renders nothing, so the comment reads clean while staying findable.
_pr_evidence_marker() {
  printf '%s%s -->' "$PR_EVIDENCE_MARKER_PREFIX" "$(_pr_evidence_key "$1")"
}

# _pr_evidence_match_id <marker> — read `<id><TAB><body>` lines on stdin, print the id of EVERY
# comment whose body carries the marker (oldest first, as the API returns them). rc 1 when none
# match. Pure: no gh, no network — this is the half the test drives with fixtures.
_pr_evidence_match_id() {
  local marker="$1" id rest found=1
  while read -r id rest; do
    case "$rest" in *"$marker"*) ;; *) continue ;; esac
    case "$id" in ''|*[!0-9]*) continue ;; esac
    printf '%s\n' "$id"
    found=0
  done
  return "$found"
}

# _pr_evidence_api_path <repo> <suffix> — the gh api path. An empty repo yields the
# {owner}/{repo} placeholders, which gh fills from the current repo (matching the old
# "omit --repo" behaviour).
_pr_evidence_api_path() {
  if [ -n "$1" ]; then printf 'repos/%s/%s' "$1" "$2"; else printf 'repos/{owner}/{repo}/%s' "$2"; fi
}

# ── pure: body composition ─────────────────────────────────────────────────────────────────────

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

# _pr_evidence_compose <caption> <file> [abs-path] — the full comment body, marker first.
# Deterministic: no timestamp, no run id. A re-run with unchanged evidence produces a byte-identical
# body, so the edit is a genuine no-op instead of churning the PR timeline.
_pr_evidence_compose() {
  local caption="$1" file="$2" abs="${3:-$2}"
  printf '%s\n\n' "$(_pr_evidence_marker "$caption")"
  if _pr_evidence_is_image "$file"; then
    _pr_evidence_image_body "$caption" "$abs" "$(basename "$file")"
  else
    _pr_evidence_text_body "$caption" "$file"
  fi
}

# ── gh seams (the only impure functions; the test stubs `gh` on PATH) ──────────────────────────

# _pr_evidence_list <repo> <pr> — `<id><TAB><json-escaped body>` per comment on the PR.
# @json keeps each body on ONE line, so a multi-line log body can never be mistaken for another
# comment's row. rc mirrors gh's, so an auth/rate-limit failure is visible to the caller.
_pr_evidence_list() {
  local p
  p="$(_pr_evidence_api_path "$1" "issues/$2/comments")"
  gh api --paginate "$p" --jq '.[] | "\(.id)\t\(.body | @json)"' 2>/dev/null
}

# _pr_evidence_edit <repo> <comment-id> <body-file> — PATCH an existing comment in place.
_pr_evidence_edit() {
  local p
  p="$(_pr_evidence_api_path "$1" "issues/comments/$2")"
  gh api --method PATCH "$p" -F "body=@$3" >/dev/null 2>&1
}

# _pr_evidence_create <repo> <pr> <body-file> — post a new comment.
_pr_evidence_create() {
  if [ -n "$1" ]; then
    gh pr comment "$2" --repo "$1" --body-file "$3" >/dev/null 2>&1
  else
    gh pr comment "$2" --body-file "$3" >/dev/null 2>&1
  fi
}

# ── the entry point ────────────────────────────────────────────────────────────────────────────

# _pr_evidence_bail <strict> <code> <result> <message> — the one place the two failure modes fork.
# Always warns and always records the result; returns <code> only under strict.
_pr_evidence_bail() {
  PR_EVIDENCE_LAST_RESULT="$3"
  echo "pr_attach_evidence: $4" >&2
  [ "$1" = 1 ] && return "$2"
  return 0
}

# pr_attach_evidence [--strict|--best-effort] <pr-number> <evidence-file> [caption]
# Upsert the evidence into the PR as a comment. Text/log files inline in a fenced block; images are
# referenced (see _pr_evidence_image_body). Caption defaults to the file basename and is the
# comment's identity — the same caption edits its own comment, a new caption gets its own.
pr_attach_evidence() {
  local strict=0 rc
  case "${PR_EVIDENCE_STRICT:-0}" in 1|true|yes|on|TRUE|YES|ON) strict=1 ;; esac
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --strict)      strict=1; shift ;;
      --best-effort) strict=0; shift ;;
      --)            shift; break ;;
      -?*)           _pr_evidence_bail "$strict" 2 bad-args "unknown option: $1"; rc=$?
                     pr_evidence_usage >&2; return "$rc" ;;
      *)             break ;;
    esac
  done

  local pr="${1:-}" file="${2:-}" caption="${3:-}"
  PR_EVIDENCE_LAST_RESULT=""

  if [ -z "$pr" ] || [ -z "$file" ]; then
    _pr_evidence_bail "$strict" 2 bad-args \
      "need <pr-number> <evidence-file> [caption] — skipping"; rc=$?
    pr_evidence_usage >&2
    return "$rc"
  fi
  if ! command -v gh >/dev/null 2>&1; then
    _pr_evidence_bail "$strict" 3 no-gh \
      "gh CLI not found — cannot post evidence to PR #$pr (skipping)"
    return $?
  fi
  if [ ! -f "$file" ]; then
    _pr_evidence_bail "$strict" 4 no-file "evidence file not found: $file (skipping)"
    return $?
  fi
  [ -n "$caption" ] || caption="$(basename "$file")"

  local repo abs tmp marker
  repo="${PR_EVIDENCE_REPO:-}"
  abs="$(cd "$(dirname "$file")" 2>/dev/null && printf '%s/%s' "$(pwd)" "$(basename "$file")")"
  [ -n "$abs" ] || abs="$file"
  marker="$(_pr_evidence_marker "$caption")"

  tmp="$(mktemp 2>/dev/null)" || {
    _pr_evidence_bail "$strict" 5 mktemp-failed "mktemp failed (skipping)"
    return $?
  }
  _pr_evidence_compose "$caption" "$file" "$abs" >"$tmp"

  # ── find this helper's own previous comment for THIS caption ────────────────────────────────
  # The lookup is a network call and can fail on its own (auth, rate limit, DNS). It must NOT be
  # confused with "no previous comment exists": that difference is exactly what decides between
  # editing and creating.
  local listing="" ids id extra
  if ! listing="$(_pr_evidence_list "$repo" "$pr")"; then
    # Strict: a failed lookup is a failure, full stop — nothing is posted, nothing looks green.
    if [ "$strict" = 1 ]; then
      PR_EVIDENCE_LAST_RESULT=lookup-failed
      echo "pr_attach_evidence: could not list comments on PR #$pr (auth/rate-limit/network) — body kept at $tmp" >&2
      return 6
    fi
    # Best-effort: FALL FORWARD to a create, deliberately risking a duplicate.
    # Missing evidence is invisible and defeats the point of the helper; a duplicate comment is
    # visible noise a human can collapse. It also does not compound: the new comment carries the
    # same marker, so the next successful run matches and edits one of them instead of adding a
    # third. The cost is one stale copy left behind, which is the honest limit of this branch.
    echo "pr_attach_evidence: comment lookup failed on PR #$pr — posting a new comment (may duplicate)" >&2
    listing=""
  fi

  ids="$(printf '%s\n' "$listing" | _pr_evidence_match_id "$marker")" || ids=""
  id="$(printf '%s\n' "$ids" | head -1)"
  extra="$(printf '%s\n' "$ids" | grep -c '[0-9]' | tr -d '[:space:]')"

  if [ -n "$id" ]; then
    if _pr_evidence_edit "$repo" "$id" "$tmp"; then
      PR_EVIDENCE_LAST_RESULT=updated
      echo "✓ evidence updated in place on PR #$pr ($caption, comment $id)" >&2
      [ "${extra:-1}" -gt 1 ] && echo "  note: ${extra} comments carry this marker — edited the oldest; the rest are stale duplicates from an earlier failed lookup" >&2
      rm -f "$tmp"
      return 0
    fi
    PR_EVIDENCE_LAST_RESULT=post-failed
    echo "✗ failed to EDIT evidence comment $id on PR #$pr — body kept at $tmp" >&2
    [ "$strict" = 1 ] && return 7
    return 0
  fi

  if _pr_evidence_create "$repo" "$pr" "$tmp"; then
    PR_EVIDENCE_LAST_RESULT=created
    echo "✓ evidence attached to PR #$pr ($caption)" >&2
    rm -f "$tmp"
    return 0
  fi
  PR_EVIDENCE_LAST_RESULT=post-failed
  echo "✗ failed to post evidence comment to PR #$pr — body kept at $tmp" >&2
  [ "$strict" = 1 ] && return 7
  return 0
}

# pr_evidence_usage — how kit-effort-pr / kit-task-pr should call this helper.
pr_evidence_usage() {
  cat <<'USAGE'
pr-evidence.sh — upsert PR evidence (build/typecheck logs, screenshots) as a PR comment.

  source scripts/lib/pr-evidence.sh
  pr_attach_evidence [--strict|--best-effort] <pr-number> <evidence-file> [caption]

kit-effort-pr should call it AFTER the PR is opened, once per gate artifact:

  pr_num=$(gh pr list --head "$branch" --json number --jq '.[0].number')
  pr_attach_evidence "$pr_num" build.log     "build"                    || true
  pr_attach_evidence "$pr_num" typecheck.log "typecheck"                || true
  pr_attach_evidence "$pr_num" screen.png    "rendered — success state" || true

UPSERT, not append. Every comment carries an invisible marker keyed on the CAPTION
(<!-- cckit:pr-evidence key=<slug> -->), so re-running on the same branch EDITS the
comment for that caption instead of stacking a new one. Different captions stay
separate comments.

Best-effort is the DEFAULT: a failure warns on stderr and returns 0, so a comment can
never break the PR flow. Pass --strict (or export PR_EVIDENCE_STRICT=1) when the
evidence must exist — then a failure returns non-zero (2 bad args, 3 no gh, 4 no file,
5 mktemp, 6 lookup, 7 create/edit) and no `|| true` may hide it. Either way
$PR_EVIDENCE_LAST_RESULT names the outcome: created · updated · bad-args · no-gh ·
no-file · mktemp-failed · lookup-failed · post-failed.

Text/log files are inlined in an auto-sized fenced block (truncated past
KIT_EVIDENCE_MAX_BYTES, default 60000). Images CANNOT be uploaded via gh/REST, so they
are referenced by local path + instructions; set KIT_EVIDENCE_URL_BASE to a host base
and the helper embeds ![caption](URL) instead.

Env: PR_EVIDENCE_REPO (OWNER/REPO; empty = gh resolves it from the current repo) ·
     PR_EVIDENCE_STRICT · KIT_EVIDENCE_URL_BASE · KIT_EVIDENCE_MAX_BYTES (default 60000).
USAGE
}
