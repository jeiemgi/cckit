#!/usr/bin/env bash
# hook-refresh-test.sh — `init --upgrade` refreshes an unmodified kit hook and reports a customized
# one without touching it (#370). Part 1 drives hook_refresh_state against a fixture kit repo with
# two template versions in its history; part 2 runs the real init.sh --upgrade on a scratch project.
# Run: bash scripts/lib/hook-refresh-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail=0
t() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
command -v jq >/dev/null 2>&1 || { echo "hook-refresh-test: jq required" >&2; exit 1; }
# shellcheck source=/dev/null
. "$ROOT/scripts/lib/hook-refresh.sh"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
g() { git -C "$1" -c user.email=t@t -c user.name=t "${@:2}"; }

# ── part 1: the verdicts, against a fixture kit with template history v1 → v2 ─────────────────
kit="$tmp/kit"; git init -q "$kit"; mkdir -p "$kit/templates/hooks"
tpl="$kit/templates/hooks/h.sh.tmpl"
printf '#!/usr/bin/env bash\necho v1\n' > "$tpl"; g "$kit" add -A; g "$kit" commit -q -m v1
printf '#!/usr/bin/env bash\necho v2\n' > "$tpl"; g "$kit" commit -qam v2
inst="$tmp/installed.sh"

printf '#!/usr/bin/env bash\necho v2\n' > "$inst"
t "the current template is current"            "$(hook_refresh_state "$inst" "$tpl" "$kit")" current
printf '#!/usr/bin/env bash\necho v1\n' > "$inst"
t "an older shipped version is refreshable"    "$(hook_refresh_state "$inst" "$tpl" "$kit")" refresh
printf '#!/usr/bin/env bash\necho v1\n# mine\n' > "$inst"
t "a customized copy is drifted"               "$(hook_refresh_state "$inst" "$tpl" "$kit")" drifted
t "no kit history (npm/brew): drifted"         "$(hook_refresh_state "$inst" "$tpl" "$tmp/no-git")" drifted
mf="$tmp/kit.manifest.json"
printf '{"schema":1,"entries":{".claude/hooks/h.sh":{"hash":"%s"}}}\n' "$(_hr_hash_file "$inst")" > "$mf"
t "the manifest hash proves it unmodified"     "$(hook_refresh_state "$inst" "$tpl" "$tmp/no-git" "$mf" .claude/hooks/h.sh)" refresh
t "a missing hook is missing"                  "$(hook_refresh_state "$tmp/nope" "$tpl" "$kit")" missing
g "$kit" mv templates/hooks/h.sh.tmpl templates/hooks/renamed.sh.tmpl; g "$kit" commit -qm rename
t "history follows a renamed template"         "$(hook_refresh_state "$inst" "$kit/templates/hooks/renamed.sh.tmpl" "$kit" 2>/dev/null; printf '#!/usr/bin/env bash\necho v1\n' > "$inst"; hook_refresh_state "$inst" "$kit/templates/hooks/renamed.sh.tmpl" "$kit")" "drifted
refresh"

# ── part 2: the real init.sh --upgrade ───────────────────────────────────────────────────────────
proj="$tmp/proj"; git init -q "$proj"; g "$proj" commit -q --allow-empty -m init
mkdir -p "$proj/.claude/hooks"
printf '{"kitVersion":"0.0.1","profile":"software","project":{"name":"H","slug":"h"},"github":{"repo":"e/h","owner":"e","projectsV2":false}}\n' > "$proj/.claude/kit.config.json"
up() { CLAUDE_PLUGIN_ROOT="$ROOT" bash "$ROOT/scripts/init.sh" --upgrade --target "$proj" --force 2>&1; }
up >/dev/null || { echo "FAIL: first init.sh --upgrade"; fail=1; }

old="$proj/.claude/hooks/guard-base-branch-commit.sh"   # unmodified, but an OLDER kit version
own="$proj/.claude/hooks/repo-hygiene.sh"               # customized by the project
printf '#!/usr/bin/env bash\n# an older kit version of this hook\nexit 0\n' > "$old"
( cd "$proj" && KIT_MANIFEST="$proj/.claude/kit.manifest.json" bash -c '
    . "$1/scripts/lib/kit-manifest.sh"; kit_manifest_init; kit_manifest_record .claude/hooks/guard-base-branch-commit.sh B init >/dev/null' _ "$ROOT" )
printf '\n# project-specific tweak\n' >> "$own"
own_before="$(cat "$own")"

# A template fix ships with a new kit version: rewind kitVersion so the upgrade runs again.
jq '.kitVersion = "0.0.1"' "$proj/.claude/kit.config.json" > "$tmp/cfg" && mv "$tmp/cfg" "$proj/.claude/kit.config.json"
out="$(up)"
t "the unmodified hook now equals the template"  "$(cmp -s "$old" "$ROOT/templates/hooks/guard-base-branch-commit.sh.tmpl" && echo same || echo differs)" same
case "$out" in *"~ .claude/hooks/guard-base-branch-commit.sh"*) echo "ok: the refresh is reported" ;; *) echo "FAIL: refresh not reported"; fail=1 ;; esac
t "the customized hook is untouched"             "$(cat "$own")" "$own_before"
case "$out" in *"! .claude/hooks/repo-hygiene.sh"*) echo "ok: the customized hook is reported as drifted" ;; *) echo "FAIL: drift not reported"; fail=1 ;; esac
case "$out" in *"= .claude/hooks/guard-raw-git-ops.sh"*) echo "ok: a current hook is just preserved" ;; *) echo "FAIL: current hook not listed as preserved"; fail=1 ;; esac

[ "$fail" -eq 0 ] && echo "hook-refresh: all passed" || echo "hook-refresh: FAILURES"
exit "$fail"
