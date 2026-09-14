#!/usr/bin/env bash
# agent-profile-test.sh — the agent-profile declaration contract (#325).
#
# Fixtures only: every assertion runs against a config written into a temp dir, so the suite never
# depends on this repo's own cckit.config.json (which declares no profiles) and stays hermetic.
# Run:  bash scripts/lib/agent-profile-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
# shellcheck shell=bash
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/agent-profile.sh"

command -v jq >/dev/null 2>&1 || { echo "agent-profile-test: jq absent — skipping"; exit 0; }

fail=0
t()  { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
rc() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> rc '[$2]' want '[$3]'"; fail=1; fi; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
CFG="$tmp/kit.config.json"
cat > "$CFG" <<'JSON'
{
  "agents": {
    "default": "build",
    "profiles": {
      "build": {
        "kind": "claude",
        "model": "claude-opus-5",
        "reasoning": "high",
        "permissions": "acceptEdits",
        "stages": ["build"],
        "write": true,
        "contextBudget": 8000,
        "args": ["--flag", "two words"]
      },
      "review": {
        "kind": "codex",
        "model": "gpt-5-codex",
        "stages": ["review", "design"]
      },
      "nostages": { "kind": "claude" }
    }
  }
}
JSON

# ── readers ────────────────────────────────────────────────────────────────────────────────────
t "names lists every declared profile" "$(ap_profile_names "$CFG" | tr '\n' ' ')" "build nostages review "
t "field reads kind"                   "$(ap_profile_field "$CFG" build kind)"    "claude"
t "field reads the vendor model"       "$(ap_profile_field "$CFG" build model)"   "claude-opus-5"
t "field reads reasoning"              "$(ap_profile_field "$CFG" build reasoning)" "high"
t "field reads permissions"            "$(ap_profile_field "$CFG" build permissions)" "acceptEdits"
t "field reads a numeric budget"       "$(ap_profile_field "$CFG" build contextBudget)" "8000"
t "field is empty for an absent key"   "$(ap_profile_field "$CFG" review reasoning)" ""
t "field is empty for an absent profile" "$(ap_profile_field "$CFG" ghost kind)" ""

# An arg containing a space must survive as ONE argument — the reason args is an argv array in the
# schema and one-per-line here, rather than a shell string something would re-split.
t "args keep a space-bearing argument intact" "$(ap_profile_args "$CFG" build | sed -n '2p')" "two words"
t "args count"                         "$(ap_profile_args "$CFG" build | wc -l | tr -d ' ')" "2"
t "args empty when undeclared"         "$(ap_profile_args "$CFG" review | wc -l | tr -d ' ')" "0"

t "stages read"                        "$(ap_profile_stages "$CFG" review | tr '\n' ' ')" "review design "

# ── write ownership ────────────────────────────────────────────────────────────────────────────
ap_profile_writes "$CFG" build;  rc "an explicit write:true profile may write" "$?" "0"
ap_profile_writes "$CFG" review; rc "write defaults to false when unstated"    "$?" "1"

# ── stage gating ───────────────────────────────────────────────────────────────────────────────
ap_stage_allows "$CFG" review review; rc "a listed stage is allowed"      "$?" "0"
ap_stage_allows "$CFG" review build;  rc "an unlisted stage is refused"   "$?" "1"
# An unstated permission is not a granted one: no `stages` key means allowed nowhere, not everywhere.
ap_stage_allows "$CFG" nostages build; rc "a profile with no stages is allowed nowhere" "$?" "1"

# ── the stage vocabulary ───────────────────────────────────────────────────────────────────────
t "built-in stage vocabulary" "$(ap_stages "$CFG" | tr '\n' ' ')" "build review design docs "
cat > "$tmp/stages.json" <<'JSON'
{ "agents": { "stages": ["build", "qa"], "profiles": { "b": { "kind": "claude", "stages": ["qa"] } } } }
JSON
t "config replaces the vocabulary" "$(ap_stages "$tmp/stages.json" | tr '\n' ' ')" "build qa "
t "env wins per invocation" "$(CCKIT_AGENT_STAGES='only' ap_stages "$CFG" | tr '\n' ' ')" "only "

# ── validation refuses BEFORE anything is created ──────────────────────────────────────────────
ap_profile_validate "$CFG" build build 2>/dev/null;  rc "a declared profile at an allowed stage passes" "$?" "0"
ap_profile_validate "$CFG" ghost 2>/dev/null;        rc "an undeclared profile is refused"              "$?" "2"
ap_profile_validate "$CFG" "" 2>/dev/null;           rc "an empty name is refused"                      "$?" "2"
ap_profile_validate "$CFG" review build 2>/dev/null; rc "a profile barred from the stage is refused"    "$?" "2"
ap_profile_validate "$CFG" build nosuch 2>/dev/null; rc "a stage outside the vocabulary is refused"     "$?" "2"

cat > "$tmp/nokind.json" <<'JSON'
{ "agents": { "profiles": { "k": { "model": "x" } } } }
JSON
ap_profile_validate "$tmp/nokind.json" k 2>/dev/null; rc "a profile with no kind is refused" "$?" "2"

cat > "$tmp/badstage.json" <<'JSON'
{ "agents": { "profiles": { "k": { "kind": "claude", "stages": ["nope"] } } } }
JSON
ap_profile_validate "$tmp/badstage.json" k 2>/dev/null; rc "a profile listing an unknown stage is refused" "$?" "2"

# The refusal must name the profile, so an operator can act on it without reading the source.
case "$(ap_profile_validate "$CFG" ghost 2>&1 >/dev/null)" in
  *ghost*) echo "ok: the refusal names the offending profile" ;;
  *) echo "FAIL: the refusal does not name the profile"; fail=1 ;;
esac

# ── the default ────────────────────────────────────────────────────────────────────────────────
t "default is echoed when it resolves" "$(ap_default_profile "$CFG" 2>/dev/null)" "build"
cat > "$tmp/dangling.json" <<'JSON'
{ "agents": { "default": "missing", "profiles": { "b": { "kind": "claude" } } } }
JSON
ap_default_profile "$tmp/dangling.json" >/dev/null 2>&1
rc "a default naming no declared profile is refused, not silently ignored" "$?" "2"
cat > "$tmp/nodefault.json" <<'JSON'
{ "agents": { "profiles": { "b": { "kind": "claude" } } } }
JSON
ap_default_profile "$tmp/nodefault.json" >/dev/null 2>&1
rc "no default declared is not an error" "$?" "0"

# ── a config with no agents block at all stays inert ───────────────────────────────────────────
echo '{}' > "$tmp/empty.json"
t "no agents block yields no profiles" "$(ap_profile_names "$tmp/empty.json" | wc -l | tr -d ' ')" "0"
ap_default_profile "$tmp/empty.json" >/dev/null 2>&1
rc "no agents block is not an error" "$?" "0"

# ── the acceptance that matters: no vendor model id is hard-coded in kit logic ──────────────────
# #318 requires stage logic to name no model. The model must reach the kit ONLY from config, so a
# grep for a vendor id across the shipped libs must come back empty.
hits="$(grep -rEl 'claude-(opus|sonnet|haiku)-[0-9]|gpt-[0-9]|gemini-[0-9]' "$ROOT/scripts/lib" "$ROOT/bin" 2>/dev/null | grep -v -- '-test\.sh$' | wc -l | tr -d ' ')"
t "no vendor model id appears in shipped lib or bin code" "$hits" "0"

[ "$fail" -eq 0 ] && echo "agent-profile-test: PASS" || echo "agent-profile-test: FAILED"
exit "$fail"
