#!/usr/bin/env bash
# shellcheck shell=bash
# pr-evidence-test.sh — covers the PR evidence upsert + its two failure modes (#224).
#
# Two defects are under test, and both were invisible before:
#   1. the helper posted with a plain `gh pr comment`, so every push stacked ANOTHER evidence
#      comment on the PR. The fix is a marker-based upsert, and the assertion that matters is
#      "two consecutive calls produce one create and one edit" — which is why the gh stub here is
#      STATEFUL: a stub that only counts calls cannot tell an upsert from an append.
#   2. best-effort swallowed a failed API call, so a caller that needed the evidence to exist had
#      no way to learn it did not. The fix is an opt-in strict mode, asserted per failure class.
#
# NETWORK-FREE and gh-FREE. The pure halves (key, marker, body, match, api path) are driven with
# fixtures; the three gh seams are driven through a PATH shim in a temp dir, so nothing here can
# reach GitHub or spam a real PR. Run:  bash scripts/lib/pr-evidence-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$ROOT/scripts/lib"
fail=0
t()    { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
has()  { case "$2" in *"$3"*) echo "ok: $1" ;; *) echo "FAIL: $1 -> '$(printf '%s' "$2" | head -3)' lacks '$3'"; fail=1 ;; esac; }
hasnt(){ case "$2" in *"$3"*) echo "FAIL: $1 -> unexpectedly contains '$3'"; fail=1 ;; *) echo "ok: $1" ;; esac; }
ne()   { if [ "$2" != "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> both are '[$2]', want different"; fail=1; fi; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# shellcheck source=/dev/null
. "$LIB/pr-evidence.sh"

# ── 1. the key: one evidence artifact, one stable identity (pure) ───────────────────────────────
t   "key is stable for the same caption"   "$(_pr_evidence_key build)" "$(_pr_evidence_key build)"
t   "key normalizes case + punctuation"    "$(_pr_evidence_key 'Build — LOG (v2)!')" "build-log-v2"
ne  "different captions -> different keys" "$(_pr_evidence_key build)" "$(_pr_evidence_key typecheck)"
a200="$(printf 'a%.0s' $(seq 1 200))"
a47="$(printf 'a%.0s' $(seq 1 47))"
t   "key length is capped"                 "$(_pr_evidence_key "$a200" | wc -c | tr -d ' ')" "48"
# 47 chars + a separator lands the cut exactly on the dash; a trailing dash would be ugly and,
# worse, would collide with the 48-char caption whose 48th char is real.
hasnt "capped key has no trailing dash"    "$(_pr_evidence_key "$a47 !!x")" "-"
# An emoji-only caption slugs to the empty string; without the checksum fallback every such
# caption would share one key and overwrite the others' comments.
t   "unsluggable caption still yields a key" "$( [ -n "$(_pr_evidence_key '🎉')" ] && echo yes )" "yes"
ne  "two unsluggable captions differ"      "$(_pr_evidence_key '🎉')" "$(_pr_evidence_key '🔥')"

# ── 2. the marker: findable by us, invisible to a reader (pure) ─────────────────────────────────
m_build="$(_pr_evidence_marker build)"
has "marker is an HTML comment (open)"  "$m_build" '<!-- cckit:pr-evidence key='
has "marker is an HTML comment (close)" "$m_build" '-->'
has "marker carries the key"            "$m_build" 'key=build'
t   "marker is one line"                "$(printf '%s' "$m_build" | wc -l | tr -d ' ')" "0"
ne  "markers differ per caption"        "$m_build" "$(_pr_evidence_marker typecheck)"

# ── 3. the body: marker first, deterministic (pure) ────────────────────────────────────────────
printf 'compiled 3 files\nno errors\n' > "$tmp/build.log"
body="$(_pr_evidence_compose build "$tmp/build.log")"
t     "body starts with the marker"      "$(printf '%s\n' "$body" | head -1)" "$m_build"
has   "body still carries the caption"   "$body" '## Evidence — build'
has   "body still inlines the log"       "$body" 'compiled 3 files'
hasnt "body has no other caption marker" "$body" "$(_pr_evidence_marker typecheck)"
# No timestamp/run-id: an unchanged re-run must produce an identical body, or every push would
# churn the PR timeline with a cosmetic edit.
t     "body is deterministic"            "$body" "$(_pr_evidence_compose build "$tmp/build.log")"
printf 'x' > "$tmp/shot.png"
has   "image body carries the marker"    "$(_pr_evidence_compose 'rendered' "$tmp/shot.png")" "$(_pr_evidence_marker rendered)"

# ── 4. matching: find OUR previous comment, and only ours (pure, fixture listing) ───────────────
# Shape mirrors _pr_evidence_list: `<id><TAB><one-line body>`. Row 3 is a human's comment, row 4 is
# a DIFFERENT evidence artifact — neither may be mistaken for the build comment.
row() { printf '%s\t%s\n' "$1" "$2"; }
listing="$( row 11 'looks good to me'
            row 22 "$m_build\\n\\n## Evidence — build"
            row 33 'nice'
            row 44 "$(_pr_evidence_marker typecheck)\\n\\n## Evidence — typecheck" )"
t "match finds our own comment"        "$(printf '%s\n' "$listing" | _pr_evidence_match_id "$m_build")" "22"
t "match ignores another artifact"     "$(printf '%s\n' "$listing" | _pr_evidence_match_id "$(_pr_evidence_marker typecheck)")" "44"
t "match rc 1 when absent"             "$(printf '%s\n' "$listing" | _pr_evidence_match_id "$(_pr_evidence_marker lint)" >/dev/null; echo $?)" "1"
t "match rc 0 when present"            "$(printf '%s\n' "$listing" | _pr_evidence_match_id "$m_build" >/dev/null; echo $?)" "0"
t "match on an empty listing rc 1"     "$(printf '' | _pr_evidence_match_id "$m_build" >/dev/null; echo $?)" "1"
t "match reports every duplicate"      "$( { row 22 "$m_build"; row 99 "$m_build"; } | _pr_evidence_match_id "$m_build" | tr '\n' ' ')" "22 99 "
t "match rejects a non-numeric id"     "$(row abc "$m_build" | _pr_evidence_match_id "$m_build" >/dev/null; echo $?)" "1"

# ── 5. api path: gh placeholders when the repo is unset (pure) ──────────────────────────────────
t "api path with an explicit repo" "$(_pr_evidence_api_path acme/widgets 'issues/7/comments')" "repos/acme/widgets/issues/7/comments"
t "api path defers to gh"          "$(_pr_evidence_api_path '' 'issues/7/comments')"           "repos/{owner}/{repo}/issues/7/comments"

# ── the gh stub: stateful, so an append is distinguishable from an upsert ───────────────────────
mkdir -p "$tmp/bin" "$tmp/state"
cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Stateful `gh` stub. State: $GH_STATE/index (id<TAB>bodyfile) + $GH_STATE/body.<id>.
# Log: one line per call in $GH_LOG ("list" | "create" | "edit <id>").
# GH_FAIL_LIST=1 makes the lookup fail; GH_FAIL_WRITE=1 makes create+edit fail.
set -u
idx="$GH_STATE/index"; [ -f "$idx" ] || : > "$idx"

if [ "${1:-}" = api ]; then
  path=""; method=GET; bodyfile=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --method) method="$2"; shift 2 ;;
      -F) case "$2" in body=@*) bodyfile="${2#body=@}" ;; esac; shift 2 ;;
      --jq) shift 2 ;;
      --paginate|api) shift ;;
      -*) shift ;;
      *) path="$1"; shift ;;
    esac
  done
  if [ "$method" = PATCH ]; then
    id="${path##*/}"
    echo "edit $id" >> "$GH_LOG"
    [ "${GH_FAIL_WRITE:-0}" = 1 ] && exit 1
    cut -f1 "$idx" | grep -qx "$id" || exit 1   # 404 on an unknown comment, like the real API
    cp "$bodyfile" "$GH_STATE/body.$id"
    exit 0
  fi
  echo "list" >> "$GH_LOG"
  [ "${GH_FAIL_LIST:-0}" = 1 ] && exit 1
  # Mirror `--jq '.[] | "\(.id)\t\(.body | @json)"'`: one line per comment, newlines/tabs escaped.
  while read -r id _; do
    [ -n "$id" ] || continue
    printf '%s\t%s\n' "$id" "$(awk '{ gsub(/\t/, "\\t"); printf "%s\\n", $0 }' "$GH_STATE/body.$id")"
  done < "$idx"
  exit 0
fi

if [ "${1:-}" = pr ] && [ "${2:-}" = comment ]; then
  bodyfile=""
  while [ "$#" -gt 0 ]; do
    case "$1" in --body-file) bodyfile="$2"; shift 2 ;; *) shift ;; esac
  done
  echo "create" >> "$GH_LOG"
  [ "${GH_FAIL_WRITE:-0}" = 1 ] && exit 1
  n=$(( $(wc -l < "$idx" | tr -d ' ') + 1 ))
  id=$(( 1000 + n ))
  cp "$bodyfile" "$GH_STATE/body.$id"
  printf '%s\t%s\n' "$id" "$GH_STATE/body.$id" >> "$idx"
  echo "https://github.com/o/r/pull/7#issuecomment-$id"
  exit 0
fi
echo "stub gh: unhandled: $*" >&2
exit 1
STUB
chmod +x "$tmp/bin/gh"

reset_stub() { rm -rf "$tmp/state"; mkdir -p "$tmp/state"; : > "$tmp/gh.log"; }
# attach [env...] -- runs pr_attach_evidence in a subshell with ONLY the stub bin on PATH, so a
# real gh on the developer's machine can never be reached.
attach() {
  GH_STATE="$tmp/state" GH_LOG="$tmp/gh.log" PATH="$tmp/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    pr_attach_evidence "$@" 2>>"$tmp/stderr.log"
}
log_calls() { tr '\n' ' ' < "$tmp/gh.log" | sed 's/ *$//'; }

# ── 6. idempotence: two calls == one create + one edit ─────────────────────────────────────────
reset_stub; : > "$tmp/stderr.log"
attach 7 "$tmp/build.log" build; rc1=$?
attach 7 "$tmp/build.log" build; rc2=$?
t "1st call rc 0"                        "$rc1" "0"
t "2nd call rc 0"                        "$rc2" "0"
t "1st call created, 2nd EDITED"         "$(log_calls)" "list create list edit 1001"
t "exactly one comment exists"           "$(wc -l < "$tmp/state/index" | tr -d ' ')" "1"
has "the stored comment carries the marker" "$(cat "$tmp/state/body.1001")" "$m_build"
t "result reports the update"             "$(attach 7 "$tmp/build.log" build; printf '%s' "$PR_EVIDENCE_LAST_RESULT")" "updated"

# an edited comment reflects the NEW evidence, not the old
reset_stub
attach 7 "$tmp/build.log" build
printf 'compiled 4 files\nstill no errors\n' > "$tmp/build.log"
attach 7 "$tmp/build.log" build
has   "edit replaced the body with fresh evidence" "$(cat "$tmp/state/body.1001")" 'compiled 4 files'
hasnt "edit dropped the stale evidence"            "$(cat "$tmp/state/body.1001")" 'compiled 3 files'

# ── 7. two artifacts on one PR are two comments ────────────────────────────────────────────────
reset_stub
printf 'no type errors\n' > "$tmp/tc.log"
attach 7 "$tmp/build.log" build
attach 7 "$tmp/tc.log"    typecheck
attach 7 "$tmp/build.log" build
t "distinct captions each get their own comment" "$(wc -l < "$tmp/state/index" | tr -d ' ')" "2"
t "and the repeat edits only its own"            "$(log_calls)" "list create list create list edit 1001"

# default caption = basename, so the same file re-run is still an upsert
reset_stub
attach 7 "$tmp/build.log"
attach 7 "$tmp/build.log"
t "default caption upserts too" "$(log_calls)" "list create list edit 1001"

# ── 8. strict propagates; best-effort does not (the whole point of the sub) ────────────────────
# 8a. a failed WRITE (the API said no). Best-effort must not report green work it did not do —
# it returns 0 by contract but records post-failed; strict returns 7.
reset_stub
GH_FAIL_WRITE=1 attach 7 "$tmp/build.log" build; t "best-effort rc 0 on a failed post" "$?" "0"
t "best-effort still records the failure" "$(GH_FAIL_WRITE=1 attach 7 "$tmp/build.log" build; printf '%s' "$PR_EVIDENCE_LAST_RESULT")" "post-failed"
GH_FAIL_WRITE=1 attach --strict 7 "$tmp/build.log" build; t "strict rc 7 on a failed post" "$?" "7"
GH_FAIL_WRITE=1 PR_EVIDENCE_STRICT=1 attach 7 "$tmp/build.log" build; t "PR_EVIDENCE_STRICT=1 propagates too" "$?" "7"
GH_FAIL_WRITE=1 PR_EVIDENCE_STRICT=1 attach --best-effort 7 "$tmp/build.log" build; t "--best-effort overrides the env" "$?" "0"

# 8b. a failed EDIT is just as fatal in strict mode (the comment exists but was not refreshed).
reset_stub
attach 7 "$tmp/build.log" build
GH_FAIL_WRITE=1 attach --strict 7 "$tmp/build.log" build; t "strict rc 7 on a failed edit" "$?" "7"

# 8c. a failed LOOKUP. Strict: rc 6, nothing posted. Best-effort: falls FORWARD to a create — a
# visible duplicate beats silently losing the evidence, and it does not compound because the new
# comment carries the same marker.
reset_stub
GH_FAIL_LIST=1 attach --strict 7 "$tmp/build.log" build; t "strict rc 6 on a failed lookup" "$?" "6"
t "strict posted nothing after a failed lookup" "$(log_calls)" "list"
reset_stub
GH_FAIL_LIST=1 attach 7 "$tmp/build.log" build; t "best-effort rc 0 on a failed lookup" "$?" "0"
t "best-effort fell forward to a create"        "$(log_calls)" "list create"
attach 7 "$tmp/build.log" build
t "and the next healthy run edits, not appends" "$(log_calls)" "list create list edit 1001"

# 8d. the pre-flight failures: bad args, missing gh, missing file.
attach --strict 2>/dev/null;                          t "strict rc 2 on missing args"  "$?" "2"
attach 2>/dev/null;                                   t "best-effort rc 0 on missing args" "$?" "0"
attach --strict --bogus 7 "$tmp/build.log" 2>/dev/null; t "strict rc 2 on a bad option" "$?" "2"
attach --strict 7 "$tmp/nope.log" build;              t "strict rc 4 on a missing file" "$?" "4"
attach 7 "$tmp/nope.log" build;                       t "best-effort rc 0 on a missing file" "$?" "0"
t "missing file is recorded" "$(attach 7 "$tmp/nope.log" build; printf '%s' "$PR_EVIDENCE_LAST_RESULT")" "no-file"
# gh absent: an empty PATH dir, so `command -v gh` genuinely fails. `hash -r` first, or bash's
# cached path for gh would still resolve and the case would pass without testing anything.
mkdir -p "$tmp/nogh"
( hash -r 2>/dev/null; PATH="$tmp/nogh" pr_attach_evidence --strict 7 "$tmp/build.log" build ) 2>/dev/null
t "strict rc 3 without gh" "$?" "3"
( hash -r 2>/dev/null; PATH="$tmp/nogh" pr_attach_evidence 7 "$tmp/build.log" build ) 2>/dev/null
t "best-effort rc 0 without gh" "$?" "0"

# ── 9. the contract surface the callers depend on ──────────────────────────────────────────────
has "usage documents the upsert"      "$(pr_evidence_usage)" "cckit:pr-evidence key="
has "usage documents strict mode"     "$(pr_evidence_usage)" "PR_EVIDENCE_STRICT"
has "usage keeps the public signature" "$(pr_evidence_usage)" "<pr-number> <evidence-file> [caption]"
has "header declares mixed"           "$(grep -m1 '^# errors:' "$LIB/pr-evidence.sh")" "mixed"
# The marker prefix is a WIRE FORMAT: evidence comments already live on open PRs, and changing it
# orphans every one of them (an upsert would silently become an append again). This pins it so that
# is a deliberate edit with a failing test, not a refactor side effect.
t "marker prefix is frozen" "$PR_EVIDENCE_MARKER_PREFIX" '<!-- cckit:pr-evidence key='

# ── 10. zsh: sources and upserts there too ─────────────────────────────────────────────────────
if command -v zsh >/dev/null 2>&1; then
  reset_stub
  zsh -c "cd '$ROOT'; . scripts/lib/pr-evidence.sh; \
    export GH_STATE='$tmp/state' GH_LOG='$tmp/gh.log'; PATH='$tmp/bin:/usr/bin:/bin'; \
    pr_attach_evidence 7 '$tmp/build.log' build >/dev/null 2>&1; \
    pr_attach_evidence 7 '$tmp/build.log' build >/dev/null 2>&1" >/dev/null 2>&1
  t "zsh: two calls == one create + one edit" "$(log_calls)" "list create list edit 1001"
  reset_stub
  zrc="$(zsh -c "cd '$ROOT'; . scripts/lib/pr-evidence.sh; \
    export GH_STATE='$tmp/state' GH_LOG='$tmp/gh.log' GH_FAIL_WRITE=1; PATH='$tmp/bin:/usr/bin:/bin'; \
    pr_attach_evidence --strict 7 '$tmp/build.log' build >/dev/null 2>&1; echo \$?" 2>/dev/null | tail -1)"
  t "zsh: strict rc 7 on a failed write" "$zrc" "7"
else
  echo "ok: zsh absent — skipping the zsh pass (dependency-light gate)"
fi

if [ "$fail" -eq 0 ]; then echo "pr-evidence-test: OK"; else echo "pr-evidence-test: FAILED"; fi
exit "$fail"
