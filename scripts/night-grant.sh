#!/usr/bin/env bash
#
# night-grant.sh — read the owner's night grant and turn it into scripts/night-run.mjs args.
#
# The brake on an unattended run is a per-night token budget the owner writes; the waivers are a
# standing base plus per-night additions; some floors can never be waived; the run stops when the
# waves are merged and the gate is green, or when an optional stopCommand passes.
#
# THE GRANT is ONE comment on the plan parent issue:
#
#   <!-- night-grant -->
#   Tonight: run the two approved waves; I accept the lockfile floor.
#
#   ```json
#   { "budget": "+2000k", "waves": [[12],[15]], "waivers": ["lockfile"], "stopCommand": null }
#   ```
#
# The latest comment starting with the marker wins — among comments the OWNER wrote. A grant sets
# the budget, the waivers and a shell `stopCommand`, so a comment counts only when GitHub reports
# its author_association as OWNER, or its author is `github.owner` or one of `night.grantors` in
# the kit config. A marker comment from anyone else is ignored and named on stderr.
#
# FLOORS. The base vocabulary below matches the engine's BASE_FLOORS / BASE_NEVER_WAIVABLE
# (scripts/night-run.mjs). A project adds its own in the kit config (cckit.config.json, or
# .claude/kit.config.json):
#
#   "night": { "floors": { "auth-dep": "the auth library version" },
#              "neverWaivable": ["auth-dep"], "gate": "pnpm typecheck && pnpm lint",
#              "grantors": ["a-maintainer"], "refuseLabels": ["hold"] }
#
# The config is resolved by kit_config_path (scripts/lib/config-path.sh): $KIT_CONFIG, else a walk
# up from the current directory. The args also carry `wipLimit` — `effort.wipLimit` (default 2,
# EFFORT_WIP_LIMIT wins) — because every executor runs `cckit effort start`, which refuses a new
# effort at that limit; the engine runs no wider than it.
#
# A bad grant is refused here, before launch, instead of at 3 a.m.; the engine still refuses a
# never-waivable floor on its own.
#
# Usage:
#   scripts/night-grant.sh read <issue>     print the engine args JSON, then `budget=+N`
#   scripts/night-grant.sh parse            same, from a comment body on stdin
#   scripts/night-grant.sh preflight [<settings.json>]
#                                           report allowlist entries an unattended run lacks
#   scripts/night-grant.sh --selftest       offline fixture test (no gh, no network)
#
# bash 3.2 / zsh safe; needs jq.

NIGHT_GRANT_MARKER='<!-- night-grant -->'
NIGHT_GRANT_BASE_FLOORS='lockfile auth security-code security-prose workflows cost secret'
NIGHT_GRANT_BASE_NEVER='workflows cost secret'
NIGHT_GRANT_REQUIRED_ALLOW='Bash(gh pr merge:*)
Bash(git push:*)
Bash(gh issue comment:*)
Bash(gh issue edit:*)
Bash(gh issue close:*)
Bash(gh api:*)'

_ng_err() { printf 'night-grant: %s\n' "$*" >&2; }

# The script's own directory, resolved at load time: inside a function zsh reports the function
# name as $0, so this cannot be deferred to the first call.
_NG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"

# _ng_config_file — the kit config path, or empty. NIGHT_GRANT_CONFIG overrides the lookup (the
# test hook; a missing file reads as "no config"). Otherwise kit_config_path resolves it, so
# $KIT_CONFIG and the walk-up from the current directory are honored like every other kit verb.
_ng_config_file() {
  if [ -n "${NIGHT_GRANT_CONFIG:-}" ]; then printf '%s\n' "$NIGHT_GRANT_CONFIG"; return 0; fi
  if ! command -v kit_config_path >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    [ -n "$_NG_DIR" ] && [ -f "$_NG_DIR/lib/config-path.sh" ] && . "$_NG_DIR/lib/config-path.sh"
  fi
  command -v kit_config_path >/dev/null 2>&1 || return 0
  kit_config_path 2>/dev/null || true
}

# _ng_cfg_jq <jq-filter> <fallback> — run a filter over the kit config; the fallback when there is
# no config or the filter fails.
_ng_cfg_jq() {
  local f; f="$(_ng_config_file)"
  if [ -n "$f" ] && [ -f "$f" ]; then jq -c "$1" "$f" 2>/dev/null || printf '%s\n' "$2"
  else printf '%s\n' "$2"; fi
}

# _ng_night_cfg — the kit config's `night` object as compact JSON, or {} when there is none.
_ng_night_cfg() {
  _ng_cfg_jq '(.night // {}) | if type == "object" then . else {} end' '{}'
}

# _ng_grantors — a JSON array of the lowercased logins allowed to write a grant: `github.owner`
# plus `night.grantors`. May be empty; an author_association of OWNER is accepted regardless.
_ng_grantors() {
  _ng_cfg_jq '[.github.owner?, ((.night.grantors? // []) | if type == "array" then .[] else empty end)]
    | map(select(type == "string" and length > 0) | ascii_downcase) | unique' '[]'
}

# _ng_wip_limit — the effort WIP limit an executor's `cckit effort start` will meet, resolved like
# _eff_wip_limit (scripts/lib/effort-ops.sh): EFFORT_WIP_LIMIT, else `effort.wipLimit`, else 2. A
# value that is not a non-negative integer falls back to 2, as it does there.
_ng_wip_limit() {
  local v="${EFFORT_WIP_LIMIT:-}"
  [ -n "$v" ] || v="$(_ng_cfg_jq '.effort.wipLimit? // empty' '' | tr -d '"')"
  case "$v" in ''|*[!0-9]*) v=2 ;; esac
  printf '%s\n' "$v"
}

# night_grant_parse — stdin: a comment body. stdout: line 1 the engine args JSON
# `{"waves":…,"grant":{"waivers":…,"stopCommand":…}}`, line 2 `budget=+N`. Exit 1 on a refused grant.
night_grant_parse() {
  local body block json budget bad
  local cfg floors never wip
  cfg="$(_ng_night_cfg)"
  # Floor names stay JSON arrays end to end: a waiver is compared as one whole string, never
  # word-split or globbed by the shell.
  floors="$(printf '%s' "$cfg" | jq -c --arg base "$NIGHT_GRANT_BASE_FLOORS" \
    '($base | split(" ")) + ((.floors // {}) | if type == "object" then keys else [] end)')"
  never="$(printf '%s' "$cfg" | jq -c --arg base "$NIGHT_GRANT_BASE_NEVER" \
    '($base | split(" ")) + ((.neverWaivable // []) | if type == "array" then map(select(type == "string")) else [] end)')"
  wip="$(_ng_wip_limit)"
  if [ "$wip" -eq 0 ]; then
    _ng_err 'refused: the effort WIP limit is 0 (effort.wipLimit / EFFORT_WIP_LIMIT), so no executor could start an effort'
    return 1
  fi
  body="$(cat | tr -d '\r')"
  case "$body" in
    "$NIGHT_GRANT_MARKER"*) ;;
    *) _ng_err "not a grant: the comment must start with $NIGHT_GRANT_MARKER"; return 1 ;;
  esac
  block="$(printf '%s\n' "$body" | awk '
    !inb && /^```json[[:space:]]*$/ { inb = 1; next }
    inb && /^```[[:space:]]*$/ { exit }
    inb { print }
  ')"
  if [ -z "$block" ]; then _ng_err 'no ```json block in the grant'; return 1; fi
  if ! json="$(printf '%s' "$block" | jq -c . 2>/dev/null)" || [ -z "$json" ]; then
    _ng_err 'the ```json block is not valid JSON'; return 1
  fi
  if [ "$(printf '%s' "$json" | jq -r 'type')" != object ]; then
    _ng_err 'the ```json block must be an object'; return 1
  fi

  budget="$(printf '%s' "$json" | jq -r 'if (.budget|type) == "string" then .budget else "" end')"
  if ! printf '%s' "$budget" | grep -Eq '^\+[1-9][0-9]*[kM]?$'; then
    _ng_err "budget missing or malformed (want +<number>[k|M], e.g. +2000k): '${budget}'"; return 1
  fi

  if ! printf '%s' "$json" | jq -e '
      (.waves | type) == "array" and (.waves | length) > 0 and
      all(.waves[]; type == "array" and length > 0 and
          all(.[]; type == "number" and . == floor and . > 0))' >/dev/null 2>&1; then
    _ng_err 'waves must be a non-empty array of non-empty arrays of issue numbers'; return 1
  fi

  if ! printf '%s' "$json" | jq -e '(.waivers // []) | type == "array" and all(.[]; type == "string")' \
      >/dev/null 2>&1; then
    _ng_err 'waivers must be an array of floor names'; return 1
  fi
  bad="$(printf '%s' "$json" | jq -r --argjson never "$never" \
    '[(.waivers // [])[] | select(. as $w | any($never[]; . == $w)) | @json] | join(", ")')"
  if [ -n "$bad" ]; then
    _ng_err "refused: $bad is never waivable — remove it from the grant"; return 1
  fi
  bad="$(printf '%s' "$json" | jq -r --argjson floors "$floors" \
    '[(.waivers // [])[] | select(. as $w | any($floors[]; . == $w) | not) | @json] | join(", ")')"
  if [ -n "$bad" ]; then
    _ng_err "unknown waiver(s): $bad — the floors are: $(printf '%s' "$floors" | jq -r 'join(" ")')"; return 1
  fi

  if ! printf '%s' "$json" | jq -e '(.stopCommand // null) | . == null or (type == "string" and length > 0)' \
      >/dev/null 2>&1; then
    _ng_err 'stopCommand must be null or a non-empty string'; return 1
  fi

  printf '%s' "$json" | jq -c --argjson cfg "$cfg" --argjson wip "$wip" '{waves: .waves, wipLimit: $wip}
    + (if ($cfg.gate | type) == "string" then {gate: $cfg.gate} else {} end)
    + (if ($cfg.refuseLabels | type) == "array" then {refuseLabels: $cfg.refuseLabels} else {} end)
    + {grant: {waivers: ((.waivers // []) | unique), stopCommand: (.stopCommand // null),
               extraFloors: ($cfg.floors // {}), neverWaivable: ($cfg.neverWaivable // [])}}'
  printf 'budget=%s\n' "$budget"
}

# night_grant_pick — stdin: a JSON array of comments, oldest first, each
# `{"body":…,"login":…,"association":…}`. stdout: the latest body that starts with the marker AND
# was written by the owner — author_association OWNER, or a login in _ng_grantors. Exit 1 when no
# such comment exists. A marker comment by anyone else never counts, however recent: the grant
# carries the budget, the waivers and a shell command. An entry with no author (a bare string) is
# unauthenticated and is skipped too.
night_grant_pick() {
  local all picked ignored grantors defs
  grantors="$(_ng_grantors)"
  all="$(cat)"
  defs='def grants: [.[] | select(type == "object" and (.body | type) == "string")
                          | select(.body | gsub("\r"; "") | startswith($m))];
        def by_owner: .association == "OWNER"
          or (((.login // "") | ascii_downcase) as $l | any($g[]; . == $l));'
  picked="$(printf '%s' "$all" | jq -r --arg m "$NIGHT_GRANT_MARKER" --argjson g "$grantors" \
    "$defs"' [grants[] | select(by_owner) | .body] | last // empty' 2>/dev/null)"
  ignored="$(printf '%s' "$all" | jq -r --arg m "$NIGHT_GRANT_MARKER" --argjson g "$grantors" \
    "$defs"' [grants[] | select(by_owner | not) | (.login // "unknown")] | unique | join(", ")' 2>/dev/null)"
  [ -z "$ignored" ] || _ng_err "ignored a grant comment not written by the owner (from: $ignored)"
  if [ -z "$picked" ]; then
    _ng_err "no comment by the owner starts with $NIGHT_GRANT_MARKER"; return 1
  fi
  printf '%s\n' "$picked"
}

# night_grant_read <issue> — fetch the issue's comments with their authors, pick the owner's latest
# grant, parse it.
night_grant_read() {
  local issue="${1:-}" comments picked
  case "$issue" in ''|*[!0-9]*) _ng_err 'usage: night_grant_read <issue-number>'; return 2 ;; esac
  if ! comments="$(gh api --paginate "repos/{owner}/{repo}/issues/$issue/comments" \
      --jq '.[] | {body, login: .user.login, association: .author_association} | @json' < /dev/null)"; then
    _ng_err "could not read the comments of #$issue"; return 1
  fi
  picked="$(printf '%s\n' "$comments" | jq -s . | night_grant_pick)" || return 1
  printf '%s\n' "$picked" | night_grant_parse
}

# night_grant_preflight [<settings.json>] — report what the TRACKED settings allowlist lacks for an
# unattended run. Exit 1 when anything is missing. Never edits the file.
night_grant_preflight() {
  local file="${1:-}" top allow req prefix missing=0
  if [ -z "$file" ]; then
    top="$(git rev-parse --show-toplevel 2>/dev/null)" || { _ng_err 'not in a git checkout'; return 2; }
    file="$top/.claude/settings.json"
  fi
  if [ ! -f "$file" ]; then _ng_err "no settings file at $file"; return 2; fi
  if ! allow="$(jq -r '(.permissions.allow // [])[]' "$file" 2>/dev/null)"; then
    _ng_err "unreadable settings file $file"; return 2
  fi
  while IFS= read -r req; do
    [ -n "$req" ] || continue
    prefix="${req#"Bash("}"; prefix="${prefix%":*)"}"
    if _ng_allow_covers "$prefix" "$allow"; then
      printf '  ok      %s\n' "$req"
    else
      printf '  MISSING %s\n' "$req"; missing=$((missing + 1))
    fi
  done <<EOF
$NIGHT_GRANT_REQUIRED_ALLOW
EOF
  if [ "$missing" -gt 0 ]; then
    printf 'night-grant preflight: %s allowlist entr%s missing in %s (add them by hand; this never edits it)\n' \
      "$missing" "$( [ "$missing" -eq 1 ] && echo y || echo ies)" "$file"
    return 1
  fi
  printf 'night-grant preflight: OK (%s)\n' "$file"
}

# _ng_allow_covers <command-prefix> <allow-list, one per line> — true when an entry allows it:
# `Bash`, `Bash(*)`, or `Bash(<p>:*)` / `Bash(<p> *)` where the command starts with <p> on a word.
_ng_allow_covers() {
  local cmd="$1" entry p
  while IFS= read -r entry; do
    case "$entry" in
      Bash|'Bash(*)') return 0 ;;
      'Bash('*':*)') p="${entry#"Bash("}"; p="${p%":*)"}" ;;
      'Bash('*' *)') p="${entry#"Bash("}"; p="${p%" *)"}" ;;
      *) continue ;;
    esac
    case "$cmd" in "$p"|"$p "*) return 0 ;; esac
  done <<EOF
$2
EOF
  return 1
}

# ── selftest (offline) ────────────────────────────────────────────────────────────────────────
night_grant_selftest() {
  local fails=0 out st tmp cfg work
  NIGHT_GRANT_CONFIG="${TMPDIR:-/tmp}/night-grant-no-config-$$.json"; export NIGHT_GRANT_CONFIG
  unset EFFORT_WIP_LIMIT KIT_CONFIG
  _t() { # <label> <want> <got>
    if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
    else printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$1" "$2" "$3"; fails=$((fails + 1)); fi
  }
  _grant() { # <json> — a grant comment around a json block
    printf '%s\nTonight: two waves.\n\n```json\n%s\n```\n' "$NIGHT_GRANT_MARKER" "$1"
  }

  # parse — the happy path
  out="$(_grant '{"budget":"+2000k","waves":[[12],[15]],"waivers":["lockfile"],"stopCommand":null}' \
    | night_grant_parse 2>/dev/null)"; st=$?
  _t "parse: a valid grant exits 0" 0 "$st"
  _t "parse: line 1 is the engine args" \
    '{"waves":[[12],[15]],"wipLimit":2,"grant":{"waivers":["lockfile"],"stopCommand":null,"extraFloors":{},"neverWaivable":[]}}' \
    "$(printf '%s\n' "$out" | sed -n 1p)"
  _t "parse: line 2 is the budget" 'budget=+2000k' "$(printf '%s\n' "$out" | sed -n 2p)"

  out="$(_grant '{"budget":"+3M","waves":[[1,2]],"stopCommand":"pnpm typecheck"}' \
    | night_grant_parse 2>/dev/null | sed -n 1p)"
  _t "parse: absent waivers -> [] and stopCommand kept" \
    '{"waves":[[1,2]],"wipLimit":2,"grant":{"waivers":[],"stopCommand":"pnpm typecheck","extraFloors":{},"neverWaivable":[]}}' "$out"

  # parse — refusals
  _grant '{"waves":[[1]]}' | night_grant_parse >/dev/null 2>&1; st=$?
  _t "parse: no budget is refused" 1 "$st"
  _grant '{"budget":"2000k","waves":[[1]]}' | night_grant_parse >/dev/null 2>&1; st=$?
  _t "parse: budget without + is refused" 1 "$st"
  _grant '{"budget":"+2000G","waves":[[1]]}' | night_grant_parse >/dev/null 2>&1; st=$?
  _t "parse: budget with a unit other than k|M is refused" 1 "$st"
  _grant '{"budget":"+10k","waves":[]}' | night_grant_parse >/dev/null 2>&1; st=$?
  _t "parse: empty waves is refused" 1 "$st"
  _grant '{"budget":"+10k","waves":[[1],[]]}' | night_grant_parse >/dev/null 2>&1; st=$?
  _t "parse: an empty wave is refused" 1 "$st"
  _grant '{"budget":"+10k","waves":[["12"]]}' | night_grant_parse >/dev/null 2>&1; st=$?
  _t "parse: a non-integer issue is refused" 1 "$st"
  _grant '{"budget":"+10k","waves":[[1]],"waivers":["lockfle"]}' | night_grant_parse >/dev/null 2>&1; st=$?
  _t "parse: a waiver outside the floor vocabulary is refused" 1 "$st"
  out="$(_grant '{"budget":"+10k","waves":[[1]],"waivers":["lockfile","cost"]}' \
    | night_grant_parse 2>&1 >/dev/null)"; st=$?
  _t "parse: a never-waivable waiver is refused" 1 "$st"
  case "$out" in *cost*'never waivable'*) out=named ;; esac
  _t "parse: the refusal names the never-waivable floor" named "$out"

  # parse — a waiver is one whole string: never word-split, never globbed
  _grant '{"budget":"+10k","waves":[[1]],"waivers":["lockfile auth"]}' | night_grant_parse >/dev/null 2>&1; st=$?
  _t "parse: 'lockfile auth' is one unknown waiver, not two valid ones" 1 "$st"
  work="${TMPDIR:-/tmp}/night-grant-glob-$$"
  mkdir -p "$work" && : >"$work/lockfile"
  ( cd "$work" && _grant '{"budget":"+10k","waves":[[1]],"waivers":["*"]}' | night_grant_parse >/dev/null 2>&1 ); st=$?
  _t "parse: a '*' waiver is refused even where it globs to a floor name" 1 "$st"
  rm -rf "$work"

  # parse — floors and gate the project declares in its kit config
  cfg="$NIGHT_GRANT_CONFIG.fixture"
  printf '%s' '{"night":{"floors":{"auth-dep":"the auth library","build-config":"the build config"},"neverWaivable":["auth-dep"],"gate":"make check"}}' >"$cfg"
  out="$(_grant '{"budget":"+10k","waves":[[1]],"waivers":["build-config"]}' \
    | NIGHT_GRANT_CONFIG="$cfg" night_grant_parse 2>/dev/null | sed -n 1p)"
  _t "parse: a project floor is waivable and the config travels in the args" \
    '{"waves":[[1]],"wipLimit":2,"gate":"make check","grant":{"waivers":["build-config"],"stopCommand":null,"extraFloors":{"auth-dep":"the auth library","build-config":"the build config"},"neverWaivable":["auth-dep"]}}' "$out"
  _grant '{"budget":"+10k","waves":[[1]],"waivers":["auth-dep"]}' \
    | NIGHT_GRANT_CONFIG="$cfg" night_grant_parse >/dev/null 2>&1; st=$?
  _t "parse: a project never-waivable floor is refused" 1 "$st"

  # config — resolved through kit_config_path: KIT_CONFIG wins, else a walk up from the cwd
  out="$(_grant '{"budget":"+10k","waves":[[1]],"waivers":["build-config"]}' \
    | ( unset NIGHT_GRANT_CONFIG; KIT_CONFIG="$cfg" night_grant_parse 2>/dev/null ) | sed -n 1p \
    | jq -c '[.gate, .grant.neverWaivable]' 2>/dev/null)"
  _t "config: KIT_CONFIG is honored (floors, never-waivable list and gate travel)" \
    '["make check",["auth-dep"]]' "$out"
  work="${TMPDIR:-/tmp}/night-grant-walk-$$"
  mkdir -p "$work/.claude" "$work/a/b" && cp "$cfg" "$work/.claude/kit.config.json"
  out="$(_grant '{"budget":"+10k","waves":[[1]]}' \
    | ( unset NIGHT_GRANT_CONFIG; cd "$work/a/b" && night_grant_parse 2>/dev/null ) | sed -n 1p \
    | jq -r '.gate' 2>/dev/null)"
  _t "config: a nested directory walks up to the project config" 'make check' "$out"
  rm -rf "$work"
  rm -f "$cfg"

  # config — the effort WIP limit and the hold labels travel in the args
  printf '%s' '{"effort":{"wipLimit":3},"night":{"refuseLabels":["hold"]}}' >"$cfg"
  out="$(_grant '{"budget":"+10k","waves":[[1]]}' \
    | NIGHT_GRANT_CONFIG="$cfg" night_grant_parse 2>/dev/null | sed -n 1p \
    | jq -c '[.wipLimit, .refuseLabels]' 2>/dev/null)"
  _t "config: effort.wipLimit and night.refuseLabels reach the engine args" '[3,["hold"]]' "$out"
  out="$(_grant '{"budget":"+10k","waves":[[1]]}' \
    | EFFORT_WIP_LIMIT=1 NIGHT_GRANT_CONFIG="$cfg" night_grant_parse 2>/dev/null | sed -n 1p \
    | jq -c '.wipLimit' 2>/dev/null)"
  _t "config: EFFORT_WIP_LIMIT wins over effort.wipLimit" 1 "$out"
  printf '%s' '{"effort":{"wipLimit":0}}' >"$cfg"
  _grant '{"budget":"+10k","waves":[[1]]}' | NIGHT_GRANT_CONFIG="$cfg" night_grant_parse >/dev/null 2>&1; st=$?
  _t "config: a WIP limit of 0 refuses the grant (no effort could start)" 1 "$st"
  rm -f "$cfg"
  for w in workflows cost secret; do
    _grant "{\"budget\":\"+10k\",\"waves\":[[1]],\"waivers\":[\"$w\"]}" | night_grant_parse >/dev/null 2>&1; st=$?
    _t "parse: '$w' is never waivable" 1 "$st"
  done
  printf 'just a comment\n```json\n{"budget":"+10k","waves":[[1]]}\n```\n' \
    | night_grant_parse >/dev/null 2>&1; st=$?
  _t "parse: a body without the marker is refused" 1 "$st"
  printf '%s\nno block here\n' "$NIGHT_GRANT_MARKER" | night_grant_parse >/dev/null 2>&1; st=$?
  _t "parse: a grant without a json block is refused" 1 "$st"

  # pick — the owner's latest marker comment wins; nobody else's counts
  _c() { # <login> <association> <body> — one comment as the picker reads it
    jq -cn --arg l "$1" --arg a "$2" --arg b "$3" '{body: $b, login: $l, association: $a}'
  }
  out="$( { _c me OWNER "$NIGHT_GRANT_MARKER
old"; _c me OWNER unrelated; _c me OWNER "$NIGHT_GRANT_MARKER
new"; _c me OWNER 'also unrelated'; } | jq -s . | night_grant_pick 2>/dev/null | tail -1)"
  _t "pick: the owner's latest grant comment wins" new "$out"
  out="$( { _c me OWNER "$NIGHT_GRANT_MARKER
mine"; _c stranger NONE "$NIGHT_GRANT_MARKER
theirs"; } | jq -s . | night_grant_pick 2>/dev/null | tail -1)"
  _t "pick: a later grant from a stranger is ignored" mine "$out"
  out="$( { _c me OWNER "$NIGHT_GRANT_MARKER
mine"; _c helper CONTRIBUTOR "$NIGHT_GRANT_MARKER
theirs"; _c bot MEMBER "$NIGHT_GRANT_MARKER
theirs"; } | jq -s . | night_grant_pick 2>&1 >/dev/null)"
  case "$out" in *'not written by the owner'*bot*helper*) out=named ;; esac
  _t "pick: the ignored authors are named on stderr" named "$out"
  { _c stranger NONE "$NIGHT_GRANT_MARKER
theirs"; } | jq -s . | night_grant_pick >/dev/null 2>&1; st=$?
  _t "pick: only a stranger's grant exits 1" 1 "$st"
  printf '%s' '["<!-- night-grant -->\nanonymous"]' | night_grant_pick >/dev/null 2>&1; st=$?
  _t "pick: a comment with no author is never a grant" 1 "$st"
  cfg="$NIGHT_GRANT_CONFIG.fixture"
  printf '%s' '{"github":{"owner":"Acme"},"night":{"grantors":["lead"]}}' >"$cfg"
  out="$( { _c acme MEMBER "$NIGHT_GRANT_MARKER
by-owner-login"; _c stranger NONE "$NIGHT_GRANT_MARKER
theirs"; } | jq -s . | NIGHT_GRANT_CONFIG="$cfg" night_grant_pick 2>/dev/null | tail -1)"
  _t "pick: github.owner's login is the owner, whatever the letter case" by-owner-login "$out"
  out="$( { _c acme MEMBER "$NIGHT_GRANT_MARKER
old"; _c Lead MEMBER "$NIGHT_GRANT_MARKER
by-grantor"; } | jq -s . | NIGHT_GRANT_CONFIG="$cfg" night_grant_pick 2>/dev/null | tail -1)"
  _t "pick: a night.grantors login may write the grant" by-grantor "$out"
  rm -f "$cfg"
  printf '%s' '[{"body":"hello","login":"me","association":"OWNER"}]' | night_grant_pick >/dev/null 2>&1; st=$?
  _t "pick: no grant comment exits 1" 1 "$st"

  # preflight — against fixture settings files
  tmp="${TMPDIR:-/tmp}/night-grant-selftest-$$.json"
  printf '%s' '{"permissions":{"allow":["Bash(gh pr merge:*)"]}}' >"$tmp"
  out="$(night_grant_preflight "$tmp" 2>/dev/null)"; st=$?
  _t "preflight: a thin allowlist exits 1" 1 "$st"
  _t "preflight: it reports each missing entry" 5 "$(printf '%s\n' "$out" | grep -c '^  MISSING')"
  printf '%s' '{"permissions":{"allow":["Bash(gh:*)","Bash(git push:*)"]}}' >"$tmp"
  night_grant_preflight "$tmp" >/dev/null 2>&1; st=$?
  _t "preflight: a broader prefix covers its commands" 0 "$st"
  printf '%s' '{"permissions":{"allow":["Bash(ghx:*)","Bash(git:*)"]}}' >"$tmp"
  night_grant_preflight "$tmp" >/dev/null 2>&1; st=$?
  _t "preflight: a prefix only covers on a word boundary" 1 "$st"
  rm -f "$tmp"
  night_grant_preflight "$tmp" >/dev/null 2>&1; st=$?
  _t "preflight: a missing file is 2, never a silent 0" 2 "$st"

  if [ "$fails" -eq 0 ]; then printf 'night-grant selftest OK\n'; return 0; fi
  printf 'night-grant selftest FAILED (%s)\n' "$fails"; return 1
}

# ── dispatch (only when executed by name with a subcommand) ───────────────────────────────────
case "${0##*/}" in
  night-grant.sh)
    if [ $# -gt 0 ]; then
      _ng_cmd="$1"; shift
      case "$_ng_cmd" in
        read)       night_grant_read "$@" ;;
        parse)      night_grant_parse ;;
        preflight)  night_grant_preflight "$@" ;;
        --selftest|selftest) night_grant_selftest ;;
        -h|--help)  sed -n '/^# Usage/,/^# bash/p' "$0" | sed 's/^# \{0,1\}//' ;;
        *) _ng_err "unknown subcommand $_ng_cmd"; exit 2 ;;
      esac
    fi
    ;;
esac
