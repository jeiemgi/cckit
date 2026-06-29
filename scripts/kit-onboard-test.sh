#!/usr/bin/env bash
# kit-onboard-test.sh — self-test for kit-onboard persistence (#372). Runs under bash AND zsh.
# Run:  bash scripts/kit-onboard-test.sh
dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

if [ -n "${KIT_OB_TEST_INNER:-}" ]; then
  set -u
  fail=0
  t() { if [ "$2" != "$3" ]; then echo "FAIL($KIT_OB_TEST_INNER): $1 -> got '[$2]' want '[$3]'"; fail=1; else echo "ok($KIT_OB_TEST_INNER): $1"; fi; }
  OB="$dir/kit-onboard.sh"

  export KIT_PROFILE_HOME="$(mktemp -d)"
  export KIT_ASSUME_YES=1 KIT_VERSION=9.9.9 KIT_PROFILE_USER=tester
  work="$(mktemp -d)"; trap 'rm -rf "$KIT_PROFILE_HOME" "$work"' EXIT

  # status: none before global interview
  "$OB" status >/dev/null 2>&1; t "status before rc" "$?" "1"

  # global: writes profile, preserves schema/user, applies answers
  printf '%s\n' '{"name":"Ada","language":"es","mode":"enforced","plans_format":"markdown","memory":"on"}' > "$work/g.json"
  "$OB" global --answers "$work/g.json" >/dev/null 2>&1; t "global rc" "$?" "0"
  prof="$KIT_PROFILE_HOME/kit.profile.tester.json"
  t "profile created"  "$([ -f "$prof" ] && echo yes)"            "yes"
  t "schema kept"      "$(jq -r .schema "$prof")"                 "1"
  t "user kept"        "$(jq -r .user "$prof")"                   "tester"
  t "name applied"     "$(jq -r .name "$prof")"                   "Ada"
  t "nested default"   "$(jq -r .defaults.mode "$prof")"          "enforced"
  t "memory applied"   "$(jq -r .defaults.memory "$prof")"        "on"
  "$OB" status >/dev/null 2>&1; t "status after rc" "$?" "0"

  # global is mergeable (a 2nd partial run keeps prior fields)
  printf '%s\n' '{"language":"en"}' > "$work/g2.json"
  "$OB" global --answers "$work/g2.json" >/dev/null 2>&1
  t "merge keeps name"  "$(jq -r .name "$prof")"      "Ada"
  t "merge updates lang" "$(jq -r .language "$prof")" "en"

  # project: writes ./.claude/kit.config.json via operate (manifest-tracked)
  mkdir -p "$work/proj"
  printf '%s\n' '{"name":"My App","owner":"Ada","language":"es","mode":"guided","software":"no"}' > "$work/p.json"
  "$OB" project --answers "$work/p.json" --dir "$work/proj" >/dev/null 2>&1; t "project rc" "$?" "0"
  cfg="$work/proj/.claude/kit.config.json"
  t "config created"   "$([ -f "$cfg" ] && echo yes)"                          "yes"
  t "project.name"     "$(jq -r .project.name "$cfg")"                         "My App"
  t "project.mode"     "$(jq -r .mode "$cfg")"                                 "guided"
  t "manifest tracks"  "$(jq -r '.entries["'.claude/kit.config.json'"]|has("hash")' "$work/proj/.claude/kit.manifest.json")" "true"

  # project idempotent (byte-identical)
  before="$(cat "$cfg")"; "$OB" project --answers "$work/p.json" --dir "$work/proj" >/dev/null 2>&1
  t "project idempotent" "$(cat "$cfg")" "$before"

  [ "$fail" -eq 0 ] && echo "ALL OK($KIT_OB_TEST_INNER)"
  exit "$fail"
fi

rc=0; ran=0
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || continue
  ran=$((ran+1)); echo "--- $sh ---"
  rcflag=""; [ "$sh" = "zsh" ] && rcflag="--no-rcs"
  KIT_OB_TEST_INNER="$sh" PATH="$PATH" "$sh" $rcflag "$0" || rc=1
done
[ "$ran" -eq 0 ] && { echo "no shell"; exit 1; }
exit "$rc"
