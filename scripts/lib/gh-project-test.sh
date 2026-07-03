#!/usr/bin/env bash
# shellcheck shell=bash
# gh-project-test.sh — covers the board owner-type resolution adoption needs (#118). A Projects v2
# board can live under a USER login or an ORGANIZATION login, and each needs a different GraphQL root
# (user(login:) vs organization(login:)). A user-only query silently returns null for an org board.
# Covered: _ghp_owner_root resolution, kit-config exporting KIT_PROJECT_OWNER_TYPE, and
# capture-project-ids.sh selecting the matching root end-to-end (stubbed gh — no network).
# Run:  bash scripts/lib/gh-project-test.sh
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$ROOT/scripts/lib"
fail=0
t() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
has() { case "$2" in *"$3"*) echo "ok: $1" ;; *) echo "FAIL: $1 -> '$2' lacks '$3'"; fail=1 ;; esac; }
command -v jq >/dev/null 2>&1 || { echo "gh-project-test: jq required — skipping"; exit 0; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# ── _ghp_owner_root resolves from KIT_PROJECT_OWNER_TYPE ───────────────────────────────────────
# shellcheck source=/dev/null
( KIT_PROJECT_OWNER_TYPE=organization; source "$LIB/gh-project.sh"; [ "$(_ghp_owner_root)" = organization ] ) \
  && echo "ok: owner_root=organization for org type" || { echo "FAIL: org owner_root"; fail=1; }
( KIT_PROJECT_OWNER_TYPE=org; source "$LIB/gh-project.sh"; [ "$(_ghp_owner_root)" = organization ] ) \
  && echo "ok: owner_root=organization for 'org' shorthand" || { echo "FAIL: org shorthand"; fail=1; }
( unset KIT_PROJECT_OWNER_TYPE; KIT_CONFIG=/nonexistent; source "$LIB/gh-project.sh"; [ "$(_ghp_owner_root)" = user ] ) \
  && echo "ok: owner_root=user by default" || { echo "FAIL: default user owner_root"; fail=1; }

# ── kit-config exports KIT_PROJECT_OWNER_TYPE from config ──────────────────────────────────────
printf '%s' '{"github":{"projectOwnerType":"organization"}}' > "$tmp/org.json"
got="$(KIT_CONFIG="$tmp/org.json" bash -c "source '$LIB/kit-config.sh'; load_kit_config >/dev/null 2>&1; printf '%s' \"\$KIT_PROJECT_OWNER_TYPE\"")"
t "kit-config exports owner type from config" "$got" "organization"
printf '%s' '{"github":{}}' > "$tmp/none.json"
got="$(KIT_CONFIG="$tmp/none.json" bash -c "source '$LIB/kit-config.sh'; load_kit_config >/dev/null 2>&1; printf '%s' \"\$KIT_PROJECT_OWNER_TYPE\"")"
t "kit-config defaults owner type to user" "$got" "user"

# ── capture-project-ids.sh selects the matching GraphQL root (stubbed gh) ───────────────────────
# Isolated scripts dir: a copy of the script + a symlink to the real lib, so $0-relative sourcing +
# OUT path stay inside tmp. A stub gh detects the query root and returns matching-shaped JSON.
mkdir -p "$tmp/scripts" "$tmp/bin"
cp "$ROOT/scripts/capture-project-ids.sh" "$tmp/scripts/"
ln -s "$LIB" "$tmp/scripts/lib"
cat > "$tmp/bin/gh" <<'SH'
#!/usr/bin/env bash
# Record the query, then emit JSON under whichever root the query selected.
q=""; for a in "$@"; do case "$a" in query=*) q="${a#query=}" ;; esac; done
printf '%s\n' "$q" >> "$GH_QUERY_LOG"
if printf '%s' "$q" | grep -q 'organization(login'; then root=organization; else root=user; fi
cat <<JSON
{"data":{"$root":{"projectV2":{"id":"PVT_org123","fields":{"nodes":[
  {"__typename":"ProjectV2SingleSelectField","id":"F_status","name":"Status","options":[{"id":"O_todo","name":"Todo"}]},
  {"__typename":"ProjectV2FieldCommon","id":"F_plan","name":"Plan Link"}
]}}}}}
JSON
SH
chmod +x "$tmp/bin/gh"

run_capture() {  # <owner-type>
  printf '%s' "{\"github\":{\"projectsV2\":true,\"owner\":\"acme\",\"projectNumber\":3,\"projectOwnerType\":\"$1\"}}" > "$tmp/cfg.json"
  : > "$tmp/qlog"
  GH_QUERY_LOG="$tmp/qlog" KIT_CONFIG="$tmp/cfg.json" PATH="$tmp/bin:$PATH" \
    bash "$tmp/scripts/capture-project-ids.sh" >/dev/null 2>&1
}

run_capture organization
rc=$?
t "capture rc 0 (org board)" "$rc" "0"
has "capture uses organization root for an org board" "$(cat "$tmp/qlog")" "organization(login"
[ -f "$tmp/scripts/.project-ids.env" ] && has "org capture wrote PROJECT_ID" "$(cat "$tmp/scripts/.project-ids.env")" "PROJECT_ID=PVT_org123" || { echo "FAIL: no env written (org)"; fail=1; }
has "org capture wrote a field id" "$(cat "$tmp/scripts/.project-ids.env" 2>/dev/null)" "STATUS_FIELD_ID=F_status"
rm -f "$tmp/scripts/.project-ids.env"

run_capture user
has "capture uses user root for a user board" "$(cat "$tmp/qlog")" "user(login"

# ── project_issue_status: read an issue's board Status via the cheap issue.projectItems query (#124) ─
mkdir -p "$tmp/bin2"
cat > "$tmp/bin2/gh" <<'SH'
#!/usr/bin/env bash
# The issue.projectItems Status query: issue is "In Progress" on project #3 (and Todo on some other).
cat <<'JSON'
{"data":{"repository":{"issue":{"projectItems":{"nodes":[
  {"project":{"number":7},"fieldValueByName":{"name":"Todo"}},
  {"project":{"number":3},"fieldValueByName":{"name":"In Progress"}}
]}}}}}
JSON
SH
chmod +x "$tmp/bin2/gh"
st="$(PATH="$tmp/bin2:$PATH" KIT_REPO="acme/app" KIT_PROJECT_NUMBER=3 bash -c "source '$LIB/gh-project.sh'; project_issue_status 42")"
t "project_issue_status returns the board Status for our project" "$st" "In Progress"
# unresolved repo/number -> non-zero, no guess.
PATH="$tmp/bin2:$PATH" KIT_REPO="" KIT_PROJECT_NUMBER="" bash -c "source '$LIB/gh-project.sh'; project_issue_status 42" >/dev/null 2>&1
t "project_issue_status fails (rc 1) with unresolved repo/number" "$?" "1"

[ "$fail" -eq 0 ] && echo "ALL OK (gh-project)" || echo "gh-project: FAILURES"
exit "$fail"
