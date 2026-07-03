#!/usr/bin/env bash
# portable-test.sh — the foreign-repo acceptance harness (#41 / #74). cckit must operate on the
# project it is INVOKED in, never its own install dir. The core invariant: run from a FOREIGN repo,
# no verb may ever resolve cckit's OWN repo (that was the bug where `cckit sync` elsewhere read
# cckit's config and reported an empty board). This harness enforces that BY CONSTRUCTION: it
# iterates `cckit commands`, exercises every read-only verb against a foreign fixture with a stubbed
# gh, and fails if any new verb is left unclassified — so coverage can't silently rot.
# Hermetic: stubs `gh` (no network/auth). Run: bash scripts/portable-test.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CCKIT="$ROOT/bin/cckit"
fail=0
t()   { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
no()  { case "$2" in *"$3"*) echo "FAIL: $1 -> LEAKED '$3'"; fail=1 ;; *) echo "ok: $1" ;; esac; }
yes() { case "$2" in *"$3"*) echo "ok: $1" ;; *) echo "FAIL: $1 -> missing '$3' in [$2]"; fail=1 ;; esac; }

command -v jq >/dev/null 2>&1 || { echo "portable-test: jq required" >&2; exit 1; }

OWN_REPO="$(jq -r '.github.repo' "$ROOT/cckit.config.json")"     # cckit's own repo — must NEVER leak
FIX_REPO="octo/fixture-repo"

# Stub gh: log EVERY --repo it is asked about to $GH_REPO_LOG (a file, so it survives a verb that
# redirects gh's stderr), and return empty results. Also echoes REPO= to stderr for the legacy checks.
stub="$(mktemp -d)"
cat > "$stub/gh" <<'SH'
#!/usr/bin/env bash
prev=""
for a in "$@"; do
  if [ "$prev" = "--repo" ]; then
    [ -n "${GH_REPO_LOG:-}" ] && printf '%s\n' "$a" >> "$GH_REPO_LOG"
    printf 'REPO=%s\n' "$a" >&2
  fi
  prev="$a"
done
# GraphQL calls read stdin/args; a bare object keeps jq consumers happy. List calls want an array.
case "$*" in *graphql*) echo '{"data":{}}' ;; *) echo "[]" ;; esac
SH
chmod +x "$stub/gh"

# A foreign project whose config points at a DISTINCT repo, a non-default base branch, and an
# org-owned board — so we verify repo + base branch + owner type all resolve to the INVOKING project.
fix="$(mktemp -d)"
cat > "$fix/cckit.config.json" <<JSON
{ "kitVersion": "9.9.9", "project": {"name":"fixture","slug":"fixture"},
  "github": {"repo":"$FIX_REPO","owner":"octo","baseBranch":"develop",
             "projectsV2":true,"projectNumber":5,"projectOwnerType":"organization"} }
JSON
( cd "$fix" && git init -q ) 2>/dev/null

# ── config resolution: the invoking project's repo / base branch / owner type / owner ────────────
eval "$(cd "$fix" && KIT_CONFIG='' bash -c 'source "'"$ROOT"'/scripts/lib/kit-config.sh"; load_kit_config >/dev/null 2>&1;
           printf "R=%s\nB=%s\nO=%s\nT=%s\n" "$KIT_REPO" "$KIT_BASE_BRANCH" "$KIT_OWNER" "$KIT_PROJECT_OWNER_TYPE"')"
t "config resolves the invoking repo"        "$R" "$FIX_REPO"
t "config resolves the invoking base branch" "$B" "develop"
t "config resolves the invoking owner"       "$O" "octo"
t "config resolves the org owner type"       "$T" "organization"

# ── legacy targeted checks (kept) ────────────────────────────────────────────────────────────────
export GH_REPO_LOG="$fix/gh.repos"; : > "$GH_REPO_LOG"
got_repo="$(cd "$fix" && PATH="$stub:$PATH" "$CCKIT" sync --llm 2>&1 >/dev/null | sed -n 's/^REPO=//p' | tail -1)"
t "sync targets the invoking project's repo" "$got_repo" "$FIX_REPO"
got_root="$(cd "$fix" && "$CCKIT" scan --llm 2>/dev/null | jq -r .root)"
t "scan root is the invoking dir" "$got_root" "$(cd "$fix" && pwd -P)"
own_repo="$(jq -r '.github.repo' "$ROOT/cckit.config.json")"
got_own="$(cd "$ROOT" && PATH="$stub:$PATH" "$CCKIT" sync --llm 2>&1 >/dev/null | sed -n 's/^REPO=//p' | tail -1)"
t "self-host sync targets cckit's repo" "$got_own" "$own_repo"
got_ver="$(cd "$fix" && "$CCKIT" version | awk '{print $2}')"
t "version is the install version, not the project's" "$got_ver" "$(jq -r '.kitVersion' "$ROOT/cckit.config.json")"

# ── BY CONSTRUCTION: exercise every read-only verb; none may resolve cckit's OWN repo ─────────────
# Read-only board/config verbs that MUST act on the invoking project. Run each from the fixture and
# assert the gh call log never mentions cckit's own repo (the leak this whole effort guards against).
EXERCISE="sync status next plan plan-next wave gc scan doctor"
for v in $EXERCISE; do
  : > "$GH_REPO_LOG"
  ( cd "$fix" && PATH="$stub:$PATH" GH_REPO_LOG="$GH_REPO_LOG" "$CCKIT" "$v" --llm >/dev/null 2>&1 )
  no "verb '$v' never resolves cckit's own repo from a foreign checkout" "$(cat "$GH_REPO_LOG")" "$OWN_REPO"
done
# The board verbs that DO call gh with --repo must have hit the FIXTURE repo (proves real resolution).
: > "$GH_REPO_LOG"; ( cd "$fix" && PATH="$stub:$PATH" GH_REPO_LOG="$GH_REPO_LOG" "$CCKIT" gc --llm >/dev/null 2>&1 )
yes "gc resolves the invoking repo" "$(cat "$GH_REPO_LOG")" "$FIX_REPO"

# ── BY CONSTRUCTION: every verb in `cckit commands` is classified (exercised or explicitly skipped) ─
# A new verb that is neither exercised nor listed here fails the harness — forcing a coverage
# decision. SKIP holds verbs that mutate, need args, read stdin, are interactive, or act on the
# install itself (not the invoking project's board) — deliberately not driven here.
SKIP="adopt autopilot close commands completions contribute copilot debug digest effort encode-context handoff help init install migrate msg orchestrate pr release render resume start ui update version watch"
classified() { case " $EXERCISE $SKIP " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
for v in $("$CCKIT" commands); do
  classified "$v" || { echo "FAIL: verb '$v' is unclassified — add it to EXERCISE (read-only, assert no own-repo leak) or SKIP in portable-test.sh"; fail=1; }
done

rm -rf "$stub" "$fix"
[ "$fail" -eq 0 ] && echo "ALL OK (portable)" || echo "portable: FAILURES"
exit "$fail"
