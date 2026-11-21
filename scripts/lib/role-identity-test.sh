#!/bin/sh
# role-identity-test.sh — every role a shipped profile declares resolves to a display name, so the
# commit author, the PR signature and the board Role are never empty for it (#416).
# Runs the helpers under bash AND zsh. Hermetic: no network, no gh, no files written.
# Run:  bash scripts/lib/role-identity-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion

dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH='' cd -- "$dir/../.." && pwd)

if [ -n "${ROLE_TEST_INNER:-}" ]; then
  unset KIT_ROLES KIT_ROLE_EMAIL_DOMAIN KIT_AGENT_LABEL
  . "$dir/role-identity.sh"
  . "$dir/gh-project.sh"
  fail=0
  eq() { if [ "$2" != "$3" ]; then echo "FAIL($ROLE_TEST_INNER): $1 -> '[$2]', want '[$3]'"; fail=1; fi; }

  eq "role_display editor"     "$(role_display editor)"     "Editor"
  eq "role_display researcher" "$(role_display researcher)" "Researcher"
  eq "role_display analyst"    "$(role_display analyst)"    "Analyst"
  eq "role_display tech-lead (unchanged)" "$(role_display tech-lead)" "Tech Lead"
  eq "role_display unknown is empty" "$(role_display nobody)" ""
  eq "role_display blank is empty"   "$(role_display "")" ""

  eq "author editor"    "$(role_git_author editor)"   "Editor (agent)|editor@agents.local"
  eq "signature researcher" "$(role_signature researcher)" "— Researcher · agent (acting via the maintainer account)"
  eq "author unknown is empty" "$(role_git_author nobody)" ""

  # A role only the project's config declares resolves through KIT_ROLES.
  KIT_ROLES="PM
Brand Lead
Editor"
  eq "config role resolves"          "$(role_display brand-lead)" "Brand Lead"
  eq "config role signs"             "$(role_git_author brand-lead)" "Brand Lead (agent)|brand-lead@agents.local"
  eq "a slug not in the config stays empty" "$(role_display growth)" ""
  unset KIT_ROLES

  # The board Role option: found for a captured option, by display name.
  ROLE_OPT_EDITOR="opt-ed"; ROLE_OPT_RESEARCHER="opt-re"
  eq "role_option_id Editor"     "$(role_option_id "$(role_display editor)" 2>/dev/null)" "opt-ed"
  eq "role_option_id Researcher" "$(role_option_id "$(role_display researcher)" 2>/dev/null)" "opt-re"
  exit "$fail"
fi

fail=0
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || { echo "skip: $sh not installed"; continue; }
  if ROLE_TEST_INNER="$sh" "$sh" "$0"; then echo "ok: role helpers under $sh"; else fail=1; fi
done

# Every role of every shipped profile has a display name equal to the profile's own spelling.
command -v jq >/dev/null 2>&1 || { echo "skip: jq missing — profile roles not checked"; exit "$fail"; }
. "$dir/role-identity.sh"
for f in "$root"/profiles/*.json; do
  roles="$(jq -r '.roles[]' "$f")"
  old_ifs="$IFS"; IFS='
'
  for r in $roles; do
    slug="$(printf '%s' "$r" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')"
    got="$(role_display "$slug")"
    if [ "$got" = "$r" ]; then echo "ok: $(basename "$f") role '$r'"; else echo "FAIL: $(basename "$f") role '$r' (slug $slug) -> '[$got]'"; fail=1; fi
  done
  IFS="$old_ifs"
done
exit "$fail"
