#!/usr/bin/env bash
# shellcheck shell=bash
# stage-receipt.sh — one durable receipt per stage attempt (#322).
#
# A worker's conversation is not a record. It lives in a pane, it does not survive a Herdr server
# restart (pane history is off by default and may hold secrets, so cckit must never require it),
# and nothing can query it. The receipt is the record: one small JSON file per attempt, written
# where every worktree of the repo can see it, holding only what a captain needs to pick the next
# wave without reading a transcript.
#
# Keyed by issue + stage + ATTEMPT, which is what makes a retry safe. The research decision on #326
# is explicit: operations must be idempotent and safe to re-run after an unknown result. Re-running
# one attempt rewrites its own file; a genuinely new try takes the next number and neither loses
# the other. Nothing appends, so a retry never doubles a record.
#
# The five reported fields are #318's acceptance and E318.5's receipt contract, verbatim — that
# contract is the format this file parses, so the prompt and the parser cannot drift apart. The
# resolved profile, its tier, where it was resolved from, and its permission policy are recorded
# alongside, per #326: a run's effective agent and policy must be auditable after the fact.
#
#   sr_dir                                  the receipts directory (does not create it)
#   sr_path <issue> <stage> <attempt>       one receipt's absolute path
#   sr_next_attempt <issue> <stage>         highest recorded attempt + 1 (1 when none)
#   sr_parse                                stdin: a worker's report -> tab-separated fields
#   sr_validate <outcome> <gate> <next>     rc 2 with the vocabulary when a value is not in it
#   sr_record <issue> <stage> <attempt> …   parse + validate + write one receipt
#   sr_read <issue> <stage> <attempt>       echo one receipt's JSON
#   sr_latest <issue> <stage>               echo the most recent attempt's JSON
#   sr_list [<issue>]                       one `issue stage attempt outcome` row per receipt
#   sr_mirror <issue> <stage> <attempt>     upsert that receipt as a comment on the issue (#333)
#
# errors: mixed — the parsers are pure; sr_record returns 2 on an invalid field, 3 without jq,
# 1 when the state directory cannot be created.

# BASH_SOURCE is bash-only and empty under zsh, the session shell here; `dirname ""` then yields
# "." and the sibling source below silently missed. Same defect and same fix as kit-gc.sh:38 (#219):
# `${BASH_SOURCE[0]:-$0}` covers zsh, CDPATH='' and the redirect stop an interactive zsh echoing the
# directory into the substitution.
# The forge port (E537): every GitHub call goes through forge_* / gh_rest_* (lib/forge/gh-rest.sh).
if ! command -v gh_rest_issue_json >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  . "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)/forge/gh-rest.sh"
fi

_sr_dir="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=/dev/null
command -v kit_state_dir >/dev/null 2>&1 || . "$_sr_dir/kit-state.sh"

# The controlled vocabularies. They are the receipt contract's, and a captain branches on them, so
# a value outside them is not a receipt with a typo — it is a routing decision nobody can make.
SR_OUTCOMES="merged pr-open closed-no-op blocked"
SR_GATES="pass fail"
SR_STAGES="build review design docs qa none"

_sr_need_jq() {
  command -v jq >/dev/null 2>&1 || { echo "stage-receipt: jq is required to read and write receipts" >&2; return 3; }
}

_sr_in() {
  local want="$1" list="$2" x
  for x in $list; do [ "$x" = "$want" ] && return 0; done
  return 1
}

# sr_dir — where receipts live. Under the shared state dir, so the same directory answers from
# every worktree: a receipt written by a worker in its own isolation worktree has to be readable
# by the captain standing somewhere else, which is the entire point of kit_state_dir.
sr_dir() { printf '%s/receipts\n' "$(kit_state_dir)"; }

# sr_path <issue> <stage> <attempt> — one receipt. The filename IS the key, so two writes of the
# same attempt land on the same file and the second replaces the first.
sr_path() {
  local n="${1:-}" stage="${2:-}" attempt="${3:-1}"
  [ -n "$n" ] && [ -n "$stage" ] || { echo "sr_path: <issue> <stage> required" >&2; return 2; }
  printf '%s/%s-%s-%s.json\n' "$(sr_dir)" "$n" "$stage" "$attempt"
}

# sr_next_attempt <issue> <stage> — the number a NEW try should use. Derived from what is on disk
# rather than kept in a counter: a counter is state that can disagree with the files it counts.
sr_next_attempt() {
  local n="${1:-}" stage="${2:-}" d f max=0 a
  [ -n "$n" ] && [ -n "$stage" ] || { echo "sr_next_attempt: <issue> <stage> required" >&2; return 2; }
  d="$(sr_dir)"
  [ -d "$d" ] || { printf '1\n'; return 0; }
  # Listed and filtered, not globbed: under zsh a glob that matches nothing is an ERROR (nomatch),
  # so the first receipt of a stage in a directory that already held another stage's aborted.
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    a="${f##*-}"; a="${a%.json}"
    [ "$a" -gt "$max" ] && max="$a"
  done <<EOF
$(ls "$d" 2>/dev/null | grep -E "^$n-$stage-[0-9]+\.json\$")
EOF
  printf '%s\n' "$(( max + 1 ))"
}

# sr_parse — stdin is whatever the worker reported; echo the five contract fields, tab-separated,
# in contract order: outcome, url, gate, blocker, next stage.
#
# Only the labelled lines are read, so a worker that wraps its receipt in prose still parses. The
# LAST occurrence of each label wins: a worker that restates its receipt after a correction means
# the correction, and taking the first would record the value it just retracted.
sr_parse() {
  awk '
    function val(s) { sub(/^[^:]*:[[:space:]]*/, "", s); gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    /^[[:space:]]*outcome[[:space:]]*:/      { o = val($0) }
    /^[[:space:]]*url[[:space:]]*:/          { u = val($0) }
    /^[[:space:]]*gate[[:space:]]*:/         { g = val($0) }
    /^[[:space:]]*blocker[[:space:]]*:/      { b = val($0) }
    /^[[:space:]]*next[ _]stage[[:space:]]*:/ { s = val($0) }
    END { printf "%s\t%s\t%s\t%s\t%s\n", o, u, g, b, s }
  '
}

# sr_invalid_fields <outcome> <gate> <next-stage> — echo the name of each field whose value is
# outside its vocabulary, one per line. Empty output means the receipt is clean.
#
# An odd value is RECORDED and flagged, not refused. Refusing looked defensible — a crashed worker
# already leaves no receipt, so "no receipt" is a case the captain must handle regardless — but it
# collapses two states the captain has to tell apart:
#
#   agent crashed                         -> no receipt   -> re-run the whole stage
#   agent finished, wrote `outcome: shipped` -> no receipt -> re-run work that is already DONE
#
# The second has a PR sitting there; it just used a word outside the list. Keeping the value and
# naming the offending field preserves that difference, which is what lets a wave keep moving
# without a human deciding which of the two it is looking at.
#
# `gate` is checked on its first word only: `fail — shellcheck` is well-formed, and the detail
# after the dash is the useful part.
sr_invalid_fields() {
  local outcome="${1:-}" gate="${2:-}" next="${3:-}" g
  _sr_in "$outcome" "$SR_OUTCOMES" || printf 'outcome\n'
  g="${gate%%[[:space:]]*}"; g="${g%%—*}"
  _sr_in "$g" "$SR_GATES" || printf 'gate\n'
  _sr_in "$next" "$SR_STAGES" || printf 'next_stage\n'
  return 0
}

# sr_validate <outcome> <gate> <next-stage> — rc 2 naming every offending field. The hard-check
# form, for a caller that wants a receipt refused rather than flagged.
sr_validate() {
  local bad; bad="$(sr_invalid_fields "$@")"
  [ -z "$bad" ] && return 0
  printf 'stage-receipt: %s\n' "$(printf '%s' "$bad" | tr '\n' ' ')" >&2
  echo "               outcome: $SR_OUTCOMES" >&2
  echo "               gate:    $SR_GATES" >&2
  echo "               next:    $SR_STAGES" >&2
  return 2
}

# sr_record <issue> <stage> <attempt> <profile> <tier> <source> <permissions> [<head-sha>] — stdin
# is the worker's report. Parse, validate, then write. Echoes the path it wrote.
#
# <head-sha> is the commit the work applies to. It is OPTIONAL and empty by default, so every caller
# written before it stays correct — but a receipt without one cannot be checked against the revision
# it was produced from, and a gate reading such a receipt is trusting a verdict that may predate the
# code. The review gate (captain.sh) requires it for exactly that reason.
sr_record() {
  local n="${1:-}" stage="${2:-}" attempt="${3:-1}" prof="${4:-}" tier="${5:-}" src="${6:-}" perms="${7:-}" head="${8:-}"
  local parsed="" outcome="" url="" gate="" blocker="" next="" d="" p=""
  [ -n "$n" ] && [ -n "$stage" ] || { echo "sr_record: <issue> <stage> required" >&2; return 2; }
  _sr_need_jq || return $?

  parsed="$(sr_parse)"
  IFS="$(printf '\t')" read -r outcome url gate blocker next <<EOF
$parsed
EOF
  # The one hard refusal: no `outcome:` line at all means the worker reported nothing, and an
  # all-empty receipt is noise a captain has to read past. "Reported nothing" and "reported oddly"
  # are different, and only the first is worth discarding.
  [ -n "$outcome" ] || {
    echo "stage-receipt: the report has no 'outcome:' line — nothing to record" >&2
    return 2
  }
  local invalid; invalid="$(sr_invalid_fields "$outcome" "$gate" "$next")"

  d="$(sr_dir)"
  mkdir -p "$d" 2>/dev/null || { echo "stage-receipt: cannot create $d" >&2; return 1; }
  p="$(sr_path "$n" "$stage" "$attempt")"
  jq -n \
    --argjson issue "$n" --arg stage "$stage" --argjson attempt "$attempt" \
    --arg profile "$prof" --arg tier "$tier" --arg profile_source "$src" --arg permissions "$perms" \
    --arg head_sha "$head" \
    --arg outcome "$outcome" --arg url "$url" --arg gate "$gate" \
    --arg blocker "$blocker" --arg next_stage "$next" \
    --arg recorded_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg invalid "$invalid" \
    '{issue:$issue, stage:$stage, attempt:$attempt,
      profile:$profile, tier:$tier, profile_source:$profile_source, permissions:$permissions,
      head_sha:$head_sha,
      outcome:$outcome, url:$url, gate:$gate, blocker:$blocker, next_stage:$next_stage,
      invalid:($invalid | split("\n") | map(select(length > 0))),
      recorded_at:$recorded_at}' > "$p" || return 1
  printf '%s\n' "$p"
}

# sr_read <issue> <stage> <attempt> — echo one receipt. rc 1 when it does not exist.
sr_read() {
  local p; p="$(sr_path "$@")" || return 2
  [ -f "$p" ] || return 1
  cat "$p"
}

# sr_latest <issue> <stage> — echo the highest-numbered attempt's receipt. rc 1 when there is none.
sr_latest() {
  local n="${1:-}" stage="${2:-}" a
  a="$(sr_next_attempt "$n" "$stage")" || return 2
  [ "$a" -gt 1 ] || return 1
  sr_read "$n" "$stage" "$(( a - 1 ))"
}

# sr_list [<issue>] — one `issue stage attempt outcome` row per receipt, sorted. Every receipt when
# no issue is given.
sr_list() {
  local n="${1:-}" d f
  _sr_need_jq || return $?
  d="$(sr_dir)"
  [ -d "$d" ] || return 0
  # Listed and filtered for the same zsh reason as sr_next_attempt.
  ls "$d" 2>/dev/null | grep -E "^${n:+$n-}.*\.json\$" | while IFS= read -r f; do
    f="$d/$f"
    [ -f "$f" ] || continue
    jq -r '[(.issue|tostring), .stage, (.attempt|tostring),
            (.outcome + (if ((.invalid // []) | length) > 0 then " (invalid: " + ((.invalid|join(","))) + ")" else "" end))]
           | @tsv' "$f" 2>/dev/null
  done | sort -k1,1n -k2,2 -k3,3n
}

# _sr_same_as_latest <issue> <stage> <outcome> <url> <gate> <blocker> <next> — rc 0 when the latest
# receipt already says exactly this.
_sr_same_as_latest() {
  local n="$1" stage="$2" prev
  prev="$(sr_latest "$n" "$stage" 2>/dev/null)" || return 1
  [ -n "$prev" ] || return 1
  # Field by field through jq, not by joining both sides into one string: a joined comparison needs
  # a separator that cannot occur in a field, and the obvious candidate (a NUL) does not survive
  # command substitution at all.
  printf '%s' "$prev" | jq -e \
    --arg o "$3" --arg u "$4" --arg g "$5" --arg b "$6" --arg s "$7" \
    '.outcome == $o and .url == $u and .gate == $g and .blocker == $b and .next_stage == $s' \
    >/dev/null 2>&1
}

# sr_cli <args> — `cckit agent receipt` (old name `cckit receipt`).
#
# The WORKER records its own receipt. Nothing else can: cckit does not read pane output, and #326
# is explicit that pane history is off by default, may hold secrets, and must never be required.
# A receipt the worker writes through a verb is durable whether or not its pane survives.
#
# The attempt number is allocated HERE rather than passed in, because the worker does not know it.
# A re-run whose five fields are IDENTICAL to the latest receipt rewrites that attempt instead of
# taking a new one — that is what makes the verb safe to retry after an unknown result, the #326
# requirement. A re-run that says something DIFFERENT genuinely is a new attempt and gets its own
# number, so neither record is lost.
sr_cli() {
  # Every local gets a value: `local n stage` leaves them UNSET, not empty, and a caller running
  # under `set -u` (bin/cckit does) dies on the first reference instead of reaching the refusal.
  local sub="${1:-}" n="" stage="" attempt="" prof="" tier="" src="" perms="" report="" remote=1
  local trail="" dry=""
  case "$sub" in
    list) shift; sr_list "${1:-}"; return $? ;;
    show)
      shift
      [ -n "${1:-}" ] && [ -n "${2:-}" ] || { echo "cckit agent receipt show <issue> <stage> [<attempt>]" >&2; return 2; }
      if [ -n "${3:-}" ]; then sr_read "$1" "$2" "$3"; else sr_latest "$1" "$2"; fi
      return $?
      ;;
    ''|-h|--help)
      cat >&2 <<'EOF'
cckit agent receipt <issue> --stage <stage> [--attempt <n>] [--profile <p>] [--tier <t>]
                      [--source <where>] [--permissions <policy>] [--no-remote]
                      < the report on stdin
cckit agent receipt <issue> --report <file> [--dry-run]
cckit agent receipt list [<issue>]
cckit agent receipt show <issue> <stage> [<attempt>]

Stages:   build review design docs qa none
Outcomes: merged pr-open closed-no-op blocked

The receipt is written locally AND mirrored as a comment on the issue. --no-remote (or
CCKIT_RECEIPT_REMOTE=0) writes the file and posts nothing; a remote failure only warns.

--report posts the trail comment for a step report (sections: Status · Done · Waiting for a
yes · Numbers · Failing or risky · Open questions · Next step): the Status head, the report's
URLs, the Waiting for a yes items and the report's file name, capped at 1500 characters. It
is refused when it would carry a private leak-list word or a home path. --dry-run prints it.
EOF
      return 2
      ;;
  esac

  n="$1"; shift
  case "$n" in ''|*[!0-9]*) echo "cckit receipt: <issue> must be a number, got '$n'" >&2; return 2 ;; esac
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --stage)         stage="$2"; shift 2 ;;
      --stage=*)       stage="${1#*=}"; shift ;;
      --attempt)       attempt="$2"; shift 2 ;;
      --attempt=*)     attempt="${1#*=}"; shift ;;
      --profile)       prof="$2"; shift 2 ;;
      --profile=*)     prof="${1#*=}"; shift ;;
      --tier)          tier="$2"; shift 2 ;;
      --tier=*)        tier="${1#*=}"; shift ;;
      --source)        src="$2"; shift 2 ;;
      --source=*)      src="${1#*=}"; shift ;;
      --permissions)   perms="$2"; shift 2 ;;
      --permissions=*) perms="${1#*=}"; shift ;;
      --no-remote)     remote=0; shift ;;
      --report)        [ -n "${2:-}" ] || { echo "cckit receipt: --report needs a file" >&2; return 2; }
                       trail="$2"; shift 2 ;;
      --report=*)      trail="${1#*=}"; shift ;;
      --dry-run)       dry=--dry-run; shift ;;
      *) echo "cckit receipt: unknown arg '$1'" >&2; return 2 ;;
    esac
  done
  # The trail mode (#572): post a short comment from a step report file. No stdin, no receipt.
  if [ -n "$trail" ]; then
    sr_trail_post "$n" "$trail" "$dry"
    return $?
  fi
  [ -z "$dry" ] || { echo "cckit receipt: --dry-run goes with --report <file>" >&2; return 2; }
  [ -n "$stage" ] || { echo "cckit receipt: --stage is required (one of: $SR_STAGES)" >&2; return 2; }
  _sr_in "$stage" "$SR_STAGES" || { echo "cckit receipt: stage '$stage' is not one of: $SR_STAGES" >&2; return 2; }
  _sr_need_jq || return $?

  report="$(cat)"
  if [ -z "$attempt" ]; then
    local pf o u g b s
    pf="$(printf '%s\n' "$report" | sr_parse)"
    IFS="$(printf '\t')" read -r o u g b s <<PARSED
$pf
PARSED
    if _sr_same_as_latest "$n" "$stage" "$o" "$u" "$g" "$b" "$s"; then
      attempt="$(( $(sr_next_attempt "$n" "$stage") - 1 ))"
    else
      attempt="$(sr_next_attempt "$n" "$stage")"
    fi
  fi
  local written
  written="$(printf '%s\n' "$report" | sr_record "$n" "$stage" "$attempt" "$prof" "$tier" "$src" "$perms")" || return $?
  printf '%s\n' "$written"

  # Mirror AFTER the local write, never instead of it (#333). sr_mirror is best-effort and always
  # returns 0, so a network failure cannot turn a recorded receipt into a failed command.
  if [ "$remote" -eq 1 ]; then
    sr_mirror "$n" "$stage" "$attempt" "$written"
  else
    SR_MIRROR_LAST_RESULT=no-remote
  fi
  return 0
}

# ── the GitHub mirror (#333) ────────────────────────────────────────────────────────────────────
# The local file is per-machine and gitignored. `effort-model.md` opens with "GitHub is the single
# source of truth" and #326 calls receipts the durable workflow record — a record that dies with
# the clone is neither. So every receipt is ALSO posted as a comment on its issue.
#
# The local store is not moved. It is what makes `cckit receipt list` and `show` answer offline,
# with no network round trip per read; the mirror is a second copy, not a relocation.
#
# UPSERT on the same marker pattern as pr-evidence.sh, keyed by issue+stage+ATTEMPT — the same key
# the local file uses. Re-running one attempt edits that attempt's comment; a genuinely new attempt
# gets its own. Neither doubles a record, which matches what sr_path already guarantees on disk.
#
# BEST-EFFORT BY DESIGN. Every remote failure warns and returns 0, because the local write has
# already succeeded by the time this runs: a receipt lost because the network blipped is worse than
# one that is only local. `$SR_MIRROR_LAST_RESULT` names the outcome so a caller can still tell —
# created · updated · no-gh · no-file · no-remote · lookup-failed · post-failed.

SR_MIRROR_LAST_RESULT="${SR_MIRROR_LAST_RESULT:-}"

# Stable across versions by contract: changing it orphans every receipt comment already posted, so
# an older cckit's comments would be appended to instead of edited.
SR_MARKER_PREFIX='<!-- cckit:receipt key='

# _sr_marker <issue> <stage> <attempt> — the invisible identity line. GitHub renders nothing.
_sr_marker() { printf '%s%s-%s-%s -->' "$SR_MARKER_PREFIX" "$1" "$2" "$3"; }

# _sr_api_path <repo> <suffix> — an empty repo yields the {owner}/{repo} placeholders, which gh
# fills from the current repo.
_sr_api_path() {
  if [ -n "$1" ]; then printf 'repos/%s/%s' "$1" "$2"; else printf 'repos/{owner}/{repo}/%s' "$2"; fi
}

# _sr_repo — the target repo, or empty to let gh resolve it.
_sr_repo() { printf '%s' "${SR_REPO:-${KIT_REPO:-}}"; }

# _sr_mirror_body <issue> <stage> <attempt> <receipt-file> — the comment, marker first.
# Deterministic given the file, so re-posting an unchanged receipt is a genuine no-op edit rather
# than timeline churn. The JSON goes in verbatim: the receipt IS the record, and a prose rendering
# of it would be a second format to keep in sync with sr_record.
_sr_mirror_body() {
  printf '%s\n\n' "$(_sr_marker "$1" "$2" "$3")"
  printf '**cckit receipt** — stage `%s`, attempt %s\n\n' "$2" "$3"
  printf '```json\n'
  cat "$4"
  printf '```\n'
}

# _sr_mirror_list <repo> <issue> — `<id><TAB><json-escaped body>` per comment. @json keeps each
# body on ONE line so a multi-line receipt can never be mistaken for another comment's row.
_sr_mirror_list() {
  forge_rest --paginate "$(_sr_api_path "$1" "issues/$2/comments")" --jq '.[] | "\(.id)\t\(.body | @json)"' 2>/dev/null
}

# _sr_mirror_match_id <marker> — ids of every comment carrying the marker, oldest first. Pure:
# reads `<id><TAB><body>` on stdin, no gh. rc 1 when none match.
_sr_mirror_match_id() {
  local marker="$1" id rest found=1
  while read -r id rest; do
    case "$rest" in *"$marker"*) ;; *) continue ;; esac
    case "$id" in ''|*[!0-9]*) continue ;; esac
    printf '%s\n' "$id"
    found=0
  done
  return "$found"
}

_sr_mirror_edit()   { forge_rest --method PATCH "$(_sr_api_path "$1" "issues/comments/$2")" -F "body=@$3" >/dev/null 2>&1; }
_sr_mirror_create() {
  local repo="$1"; [ -n "$repo" ] || repo="$(forge_repo_from_git 2>/dev/null)" || return 1
  gh_rest_issue_comment "$repo" "$2" "@$3" >/dev/null 2>&1
}

_sr_mirror_warn() { SR_MIRROR_LAST_RESULT="$1"; echo "sr_mirror: $2" >&2; return 0; }

# sr_mirror <issue> <stage> <attempt> [<receipt-file>] — upsert the receipt onto the issue.
# Always rc 0 (see BEST-EFFORT above); read $SR_MIRROR_LAST_RESULT for what happened.
sr_mirror() {
  local n="${1:-}" stage="${2:-}" attempt="${3:-1}" file="${4:-}" repo marker ids id body rc
  [ -n "$n" ] && [ -n "$stage" ] || { echo "sr_mirror: <issue> <stage> required" >&2; return 2; }
  [ -n "$file" ] || file="$(sr_path "$n" "$stage" "$attempt")"

  case "${CCKIT_RECEIPT_REMOTE:-1}" in
    0|false|no|off|FALSE|NO|OFF) _sr_mirror_warn no-remote "CCKIT_RECEIPT_REMOTE is off — receipt written locally only"; return 0 ;;
  esac
  forge_available || { _sr_mirror_warn no-forge "no forge is configured — receipt written locally only"; return 0; }
  [ -f "$file" ] || { _sr_mirror_warn no-file "no receipt at $file"; return 0; }

  repo="$(_sr_repo)"
  marker="$(_sr_marker "$n" "$stage" "$attempt")"

  body="$(mktemp 2>/dev/null)" || { _sr_mirror_warn post-failed "no temp file"; return 0; }
  _sr_mirror_body "$n" "$stage" "$attempt" "$file" > "$body"

  # A lookup that FAILED and a lookup that found nothing are different: posting after a failed
  # lookup is how a duplicate comment appears. Separate the gh rc from the match rc.
  local listing
  listing="$(_sr_mirror_list "$repo" "$n")"; rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -f "$body"
    _sr_mirror_warn lookup-failed "could not read the comments on #$n — not posting (a blind post would duplicate)"
    return 0
  fi

  ids="$(printf '%s\n' "$listing" | _sr_mirror_match_id "$marker")" || ids=""
  if [ -n "$ids" ]; then
    id="$(printf '%s\n' "$ids" | sed -n 1p)"
    if _sr_mirror_edit "$repo" "$id" "$body"; then
      rm -f "$body"; SR_MIRROR_LAST_RESULT=updated; return 0
    fi
    rm -f "$body"; _sr_mirror_warn post-failed "could not edit comment $id on #$n"; return 0
  fi

  if _sr_mirror_create "$repo" "$n" "$body"; then
    rm -f "$body"; SR_MIRROR_LAST_RESULT=created; return 0
  fi
  rm -f "$body"; _sr_mirror_warn post-failed "could not comment on #$n"; return 0
}

# ── the agent trail (#572) ──────────────────────────────────────────────────────────────────────
# A step report is the long form of what a worker did, kept in `.cckit/reports/`, which is local and
# gitignored. Agents working in parallel cannot read each other's `.cckit/`, but they can all read
# the issue. So `cckit receipt <issue> --report <file>` posts a SHORT comment built from the report:
# the head of its `## Status`, the bare URLs it names, its `## Waiting for a yes` items, and the
# report's file name, so the trail is readable on GitHub and the full report stays local.
#
# The report format, section by section: Status · Done · Waiting for a yes · Numbers · Failing or
# risky · Open questions · Next step. Only `## Status` is required; the comment reads two sections.
# Waiting for a yes also carries one line per Spec item ending `(needs a yes)` (rules/authoring.md
# § 3), so the trail comment names every human acceptance the effort still needs.
#
# Nothing private reaches GitHub. The comment is checked against the leak fence's own word list
# (lib/core/leak-fence.sh: the built-in word, `.cckit/leak-words`, `CCKIT_LEAK_WORDS`) and
# against absolute home paths, and refused whole on a hit — the matched text is never printed.
#
# UPSERT keyed by the report's file name, on the same marker pattern as the receipt mirror: posting
# one report twice edits its comment instead of appending a second.
#
#   sr_trail_body <report> <shown-path>    the comment, marker first (pure; no forge)
#   sr_trail_check <file>                  rc 1 naming the reason when the comment must not be posted
#   sr_trail_post <issue> <report> [--dry-run]   build, check, upsert; rc 0 posted or printed

SR_TRAIL_MAX="${SR_TRAIL_MAX:-1500}"
SR_TRAIL_STATUS_LINES=6
SR_TRAIL_MARKER_PREFIX='<!-- cckit:trail report='

command -v leak_fence_patterns >/dev/null 2>&1 || . "$_sr_dir/leak-fence.sh"

# _sr_trail_section <file> <heading> — the lines under `## <heading>` up to the next `## `, blank
# lines dropped. Case-insensitive on the heading, so `## Waiting for a Yes` still reads.
_sr_trail_section() {
  awk -v want="$2" '
    /^##[[:space:]]/ {
      h = $0; sub(/^##[[:space:]]+/, "", h); sub(/[[:space:]]+$/, "", h)
      on = (tolower(h) == tolower(want)); next
    }
    on && NF { print }
  ' "$1"
}

# _sr_trail_shown_path <report> — the report's path as the comment names it: relative to the
# checkout or the primary checkout when it lives inside one, else the bare file name. Never
# absolute, so no home directory reaches the comment through it.
_sr_trail_shown_path() {
  local f="$1" dir base abs root
  dir="$(cd "$(dirname "$f")" 2>/dev/null && pwd -P)" || { basename "$f"; return 0; }
  base="$(basename "$f")"; abs="$dir/$base"
  for root in "$(git rev-parse --show-toplevel 2>/dev/null)" "$(_kit_state_root)"; do
    [ -n "$root" ] || continue
    root="$(cd "$root" 2>/dev/null && pwd -P)" || continue
    case "$abs" in "$root"/*) printf '%s\n' "${abs#"$root"/}"; return 0 ;; esac
  done
  printf '%s\n' "$base"
}

_sr_trail_marker() { printf '%s%s -->' "$SR_TRAIL_MARKER_PREFIX" "$1"; }

# sr_trail_body <report> <shown-path> — the comment. rc 2 when the report has no `## Status`.
# Capped at $SR_TRAIL_MAX characters; a cut comment says so, and its last line still names the file.
sr_trail_body() {
  local f="$1" shown="$2" status urls waiting body footer note line
  [ -f "$f" ] || { echo "cckit receipt: no report at '$f'" >&2; return 2; }
  status="$(_sr_trail_section "$f" "Status" | sed -n "1,${SR_TRAIL_STATUS_LINES}p")"
  [ -n "$status" ] || { echo "cckit receipt: the report has no '## Status' section — nothing to post" >&2; return 2; }
  urls="$(grep -oE 'https?://[^][[:space:]<>()`"'"'"']+' "$f" | sed -E 's/[.,;:]+$//' | awk '!seen[$0]++')"
  waiting="$(_sr_trail_section "$f" "Waiting for a yes")"

  body="$(_sr_trail_marker "$(basename "$f")")"
  body="$body"$'\n\n'"**cckit step report** · \`$(basename "$f")\`"
  body="$body"$'\n\n'"**Status**"
  while IFS= read -r line; do body="$body"$'\n'"> ${line:0:300}"; done <<S
$status
S
  body="$body"$'\n\n'"**Links**"
  if [ -n "$urls" ]; then
    while IFS= read -r line; do body="$body"$'\n'"- $line"; done <<S
$urls
S
  else
    body="$body"$'\n'"none"
  fi
  body="$body"$'\n\n'"**Waiting for a yes**"
  if [ -n "$waiting" ]; then
    while IFS= read -r line; do
      case "$line" in [-*]\ *) ;; *) line="- $line" ;; esac
      body="$body"$'\n'"${line:0:300}"
    done <<S
$waiting
S
  else
    body="$body"$'\n'"none"
  fi

  footer="Full report: \`$shown\` (local, not on GitHub)"
  if [ "$(( ${#body} + ${#footer} + 2 ))" -gt "$SR_TRAIL_MAX" ]; then
    note="_Truncated to $SR_TRAIL_MAX characters; the rest is in the full report._"
    body="${body:0:$(( SR_TRAIL_MAX - ${#footer} - ${#note} - 6 ))}"
    body="${body%$'\n'*}"$'\n\n'"$note"
  fi
  printf '%s\n\n%s\n' "$body" "$footer"
}

# sr_trail_check <file> — rc 0 when the comment may be posted. rc 1 names the reason on stderr and
# never the matched text: the leak fence's patterns, an absolute home path, or a pattern set that
# does not compile (a check that cannot run is not a clean check).
sr_trail_check() {
  local f="$1" pat rc
  pat="$(leak_fence_patterns | paste -sd'|' -)"
  grep -iqE "$pat" "$f" 2>/dev/null; rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "cckit receipt: refused — the comment would carry a word from the private leak list (the word is not shown)" >&2
    return 1
  elif [ "$rc" -ge 2 ]; then
    echo "cckit receipt: refused — the leak list did not compile, so the comment could not be checked" >&2
    return 1
  fi
  if grep -qE '(^|[^[:alnum:]_.])/(Users|home)/[^/[:space:]]+' "$f" \
    || { [ "${#HOME}" -gt 1 ] && grep -qF "$HOME" "$f"; }; then
    echo "cckit receipt: refused — the comment would carry an absolute home path" >&2
    return 1
  fi
  return 0
}

# sr_trail_post <issue> <report> [--dry-run] — build, check, then upsert the comment. rc 0 posted,
# printed (--dry-run), or not posted for want of a forge or with CCKIT_RECEIPT_REMOTE off (said,
# and printed); 1 a refusal or a
# forge failure; 2 a usage error or a report with no Status.
sr_trail_post() {
  local n="$1" f="$2" dry="${3:-}" tmp repo marker listing ids id rc
  tmp="$(mktemp 2>/dev/null)" || { echo "cckit receipt: no temp file" >&2; return 1; }
  sr_trail_body "$f" "$(_sr_trail_shown_path "$f")" > "$tmp" || { rc=$?; rm -f "$tmp"; return "$rc"; }
  sr_trail_check "$tmp" || { rm -f "$tmp"; echo "cckit receipt: nothing was posted to #$n" >&2; return 1; }

  if [ "$dry" = "--dry-run" ]; then
    echo "cckit receipt: dry run — the comment for #$n, not posted:" >&2
    cat "$tmp"; rm -f "$tmp"; return 0
  fi
  case "${CCKIT_RECEIPT_REMOTE:-1}" in
    0|false|no|off|FALSE|NO|OFF)
      echo "cckit receipt: CCKIT_RECEIPT_REMOTE is off — the comment was NOT posted to #$n; here it is:" >&2
      cat "$tmp"; rm -f "$tmp"; return 0 ;;
  esac
  if ! forge_available; then
    echo "cckit receipt: no forge is configured — the comment was NOT posted to #$n; here it is:" >&2
    cat "$tmp"; rm -f "$tmp"; return 0
  fi

  repo="$(_sr_repo)"; [ -n "$repo" ] || repo="$(forge_repo_from_git 2>/dev/null)" || repo=""
  [ -n "$repo" ] || { rm -f "$tmp"; echo "cckit receipt: no repo (set github.repo or an origin remote) — nothing posted" >&2; return 1; }
  marker="$(_sr_trail_marker "$(basename "$f")")"
  listing="$(_sr_mirror_list "$repo" "$n")" || {
    rm -f "$tmp"; echo "cckit receipt: could not read the comments on #$n — not posting (a blind post would duplicate)" >&2; return 1; }
  ids="$(printf '%s\n' "$listing" | _sr_mirror_match_id "$marker")" || ids=""
  if [ -n "$ids" ]; then
    id="$(printf '%s\n' "$ids" | sed -n 1p)"
    _sr_mirror_edit "$repo" "$id" "$tmp" || { rm -f "$tmp"; echo "cckit receipt: could not edit comment $id on #$n" >&2; return 1; }
    rm -f "$tmp"; echo "cckit receipt: trail comment on #$n updated"; return 0
  fi
  _sr_mirror_create "$repo" "$n" "$tmp" || { rm -f "$tmp"; echo "cckit receipt: could not comment on #$n" >&2; return 1; }
  rm -f "$tmp"; echo "cckit receipt: trail comment posted on #$n"
}
