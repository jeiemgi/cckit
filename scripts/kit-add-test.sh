#!/usr/bin/env bash
# kit-add-test.sh — self-test for kit-add module stacking (#372). Runs under bash AND zsh.
# Run:  bash scripts/kit-add-test.sh
dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

if [ -n "${KIT_ADD_TEST_INNER:-}" ]; then
  set -u
  fail=0
  t() { if [ "$2" != "$3" ]; then echo "FAIL($KIT_ADD_TEST_INNER): $1 -> got '[$2]' want '[$3]'"; fail=1; else echo "ok($KIT_ADD_TEST_INNER): $1"; fi; }
  ADD="$dir/kit-add.sh"

  export KIT_PROFILE_HOME="$(mktemp -d)"
  export KIT_ASSUME_YES=1 KIT_VERSION=9.9.9
  ws="$(mktemp -d)"; trap 'rm -rf "$KIT_PROFILE_HOME" "$ws"' EXIT
  mkdir -p "$ws/myapp"
  printf '%s\n' '{"workspace":{"name":"ws"},"mode":"guided"}' > "$ws/kit.workspace.json"
  parent_before="$(cat "$ws/kit.workspace.json")"

  # unknown module fails
  "$ADD" doesnotexist --dir "$ws/myapp" >/dev/null 2>&1; t "unknown module rc" "$?" "1"

  # add software (defaults) — island config created
  "$ADD" software --dir "$ws/myapp" >/dev/null 2>&1; t "add rc" "$?" "0"
  cfg="$ws/myapp/.claude/kit.config.json"
  t "island created"   "$([ -f "$cfg" ] && echo yes)"                  "yes"
  t "modules"          "$(jq -c .modules "$cfg")"                      '["software"]'
  t "github wizard"    "$(jq -r .github.projectsV2 "$cfg")"            "true"
  t "ci wizard"        "$(jq -r .ci.provider "$cfg")"                  "github-actions"
  t "manifest tracks"  "$(jq -r '.entries["'.claude/kit.config.json'"] | has("hash")' "$ws/myapp/.claude/kit.manifest.json")" "true"

  # parent workspace untouched
  t "parent untouched" "$(cat "$ws/kit.workspace.json")" "$parent_before"

  # idempotent: a 2nd identical run leaves the file byte-identical
  before="$(cat "$cfg")"
  "$ADD" software --dir "$ws/myapp" >/dev/null 2>&1
  t "idempotent file"  "$(cat "$cfg")" "$before"

  # --set override changes only that field; modules stay deduped
  "$ADD" software --dir "$ws/myapp" --set deploy=vercel >/dev/null 2>&1
  t "override deploy"  "$(jq -r .deploy.target "$cfg")" "vercel"
  t "modules still one" "$(jq -c .modules "$cfg")" '["software"]'

  # dry-run writes nothing new
  fresh="$(mktemp -d)"; mkdir -p "$fresh/app"
  KIT_DRY_RUN=1 "$ADD" software --dir "$fresh/app" >/dev/null 2>&1
  t "dry-run no write" "$([ -f "$fresh/app/.claude/kit.config.json" ] && echo wrote || echo clean)" "clean"
  rm -rf "$fresh"

  # ── integrations (E303.2): the same entry lists descriptors and switches one on ────────────
  has() { if grep -qF -- "$3" <<<"$2"; then echo "ok($KIT_ADD_TEST_INNER): $1"; else echo "FAIL($KIT_ADD_TEST_INNER): $1 -> '$3' not in: $2"; fail=1; fi; }
  CCKIT="$dir/../bin/cckit"
  reg="$ws/integrations"; mkdir -p "$reg"
  cp "$dir/../integrations/integration.schema.json" "$reg/"
  # desc <id> <config json> <appliesWhen json|null> -> a valid fixture descriptor
  desc() {
    jq -n --arg id "$1" --argjson c "$2" --argjson a "$3" '
      { id: $id, label: ("Fixture " + $id), summary: ("Summary of " + $id + "."), config: $c,
        detect: {run: "true"}, install: [{manager: "npm", run: "npm install -g x"}],
        verify: {run: "true"}, docs: "https://example.invalid/docs",
        attribution: {author: "Example Org", homepage: "https://example.invalid", affiliated: false,
                      notice: "cckit is not affiliated with Example Org."} }
      + (if $a == null then {} else {appliesWhen: $a} end)' > "$reg/$1.json"
  }
  desc alpha '{"key":"codeGraph.provider","value":"alpha-graph"}' '{"anyExtension":[".ts"]}'
  desc beta  '{"key":"memory.enabled"}' null
  export KIT_INTEGRATIONS_DIR="$reg"

  # no argument: every descriptor is listed, rc 0 — through the dispatcher, not only the script
  out="$(cd "$ws" && "$CCKIT" add 2>/dev/null)"; t "cckit add (no arg) rc" "$?" "0"
  has "list names alpha"      "$out" "alpha"
  has "list names beta"       "$out" "beta"
  has "list carries summary"  "$out" "Summary of beta."
  has "list names the module" "$out" "software"
  t "list --llm ids" "$(cd "$ws" && "$CCKIT" add --llm 2>/dev/null | jq -c '[.integrations[].id]')" '["alpha","beta"]'
  t "list --llm modules" "$(cd "$ws" && "$CCKIT" add --llm 2>/dev/null | jq -c '[.modules[].id] | index("software") != null')" 'true'
  # an empty registry is an answer, not an error
  emp="$ws/empty-reg"; mkdir -p "$emp"
  out="$(KIT_INTEGRATIONS_DIR="$emp" "$ADD" 2>/dev/null)"; t "empty registry rc" "$?" "0"
  has "empty registry says so" "$out" "none described yet"

  # the module path still works through the dispatcher
  mkdir -p "$ws/viacli"
  ( cd "$ws/viacli" && "$CCKIT" add software --set versioning=github >/dev/null 2>&1 ); t "cckit add software rc" "$?" "0"
  t "cckit add software wrote the island" "$(jq -r .github.projectsV2 "$ws/viacli/.claude/kit.config.json" 2>/dev/null)" "true"

  # a real add changes ONLY that integration's key
  proj="$ws/proj"; mkdir -p "$proj/.claude" "$proj/src"; : > "$proj/src/a.ts"
  printf '%s\n' '{"project":{"name":"p"},"github":{"repo":"o/r","projectsV2":false},"memory":{"enabled":false}}' > "$proj/.claude/kit.config.json"
  pcfg="$proj/.claude/kit.config.json"; before="$(jq -S . "$pcfg")"
  # dry-run first: nothing is written
  raw_before="$(cat "$pcfg")"
  KIT_DRY_RUN=1 "$ADD" alpha --dir "$proj" >/dev/null 2>&1; t "integration dry-run rc" "$?" "0"
  t "integration dry-run writes nothing" "$(cat "$pcfg")" "$raw_before"
  t "dry-run leaves no temp file" "$(ls -A "$proj/.claude" | tr '\n' ' ')" "kit.config.json "
  # declining writes nothing
  "$ADD" alpha --dir "$proj" --set enable=no >/dev/null 2>&1; t "decline rc" "$?" "0"
  t "decline writes nothing" "$(cat "$pcfg")" "$raw_before"
  "$ADD" alpha --dir "$proj" >/dev/null 2>&1; t "integration add rc" "$?" "0"
  t "key is set"              "$(jq -r .codeGraph.provider "$pcfg")" "alpha-graph"
  t "every other key kept"    "$(jq -S 'del(.codeGraph)' "$pcfg")"   "$before"
  t "only one key added"      "$(jq -c '.codeGraph' "$pcfg")"        '{"provider":"alpha-graph"}'
  t "no temp file left"       "$(ls -A "$proj/.claude" | tr '\n' ' ')" "kit.config.json "
  # idempotent: a second run leaves the file byte-identical
  again="$(cat "$pcfg")"
  "$ADD" alpha --dir "$proj" >/dev/null 2>&1; t "second add rc" "$?" "0"
  t "second add is a no-op" "$(cat "$pcfg")" "$again"
  # a descriptor with no config.value sets boolean true, and touches only its own key
  mid="$(jq -S . "$pcfg")"
  "$ADD" beta --dir "$proj" >/dev/null 2>&1
  t "boolean key set to true" "$(jq -c .memory.enabled "$pcfg")" "true"
  t "beta changed only memory.enabled" "$(jq -S '.memory.enabled = false' "$pcfg")" "$mid"
  # the self-host layout: a root cckit.config.json is the config kit_config_path resolves
  selfp="$ws/selfhost"; mkdir -p "$selfp"; printf '%s\n' '{"kitVersion":"1.0.0"}' > "$selfp/cckit.config.json"
  "$ADD" beta --dir "$selfp" >/dev/null 2>&1
  t "self-host config gets the key" "$(jq -c . "$selfp/cckit.config.json")" '{"kitVersion":"1.0.0","memory":{"enabled":true}}'
  t "self-host: no .claude config invented" "$([ -e "$selfp/.claude/kit.config.json" ] && echo made || echo none)" "none"

  # a repo the tool cannot work on: declined, rc 0, nothing written
  shp="$ws/shonly"; mkdir -p "$shp/.claude"; : > "$shp/run.sh"
  printf '%s\n' '{"project":{"name":"s"}}' > "$shp/.claude/kit.config.json"
  out="$("$ADD" alpha --dir "$shp" 2>&1)"; t "not-applicable rc" "$?" "0"
  has "not-applicable says why" "$out" ".ts"
  t "not-applicable writes nothing" "$(jq -c . "$shp/.claude/kit.config.json")" '{"project":{"name":"s"}}'

  # no project config: refused, and none is invented
  bare="$ws/bare"; mkdir -p "$bare"
  out="$(KIT_CONFIG="" "$ADD" beta --dir "$bare" 2>&1)"; t "no config rc" "$?" "1"
  has "no config names the fix" "$out" "cckit init"
  t "no config invented" "$([ -e "$bare/.claude" ] && echo made || echo none)" "none"

  # an invalid descriptor is refused before any write
  jq 'del(.verify)' "$reg/beta.json" > "$reg/gamma.json"
  out="$("$ADD" gamma --dir "$proj" 2>&1)"; t "invalid descriptor rc" "$?" "1"
  has "invalid descriptor names the field" "$out" "verify"
  rm -f "$reg/gamma.json"

  # ── a descriptor that ships a rule (E303.10): the shipped Graft descriptor, with detect forced
  # to fail so the plan is the same on a machine that has graft and one that does not ───────────
  jq '.detect.run = "false"' "$dir/../integrations/graft.json" > "$reg/graft.json"
  # a repo of only .sh files: declined, rc 0, nothing written and nothing installed
  shg="$ws/sh-graft"; mkdir -p "$shg/.claude" "$shg/scripts"; : > "$shg/scripts/run.sh"
  printf '%s\n' '{"project":{"name":"s"}}' > "$shg/.claude/kit.config.json"
  out="$("$ADD" graft --dir "$shg" 2>&1)"; t "graft on a .sh-only repo rc" "$?" "0"
  has "graft on a .sh-only repo: not offered" "$out" "not offered here"
  t "graft on a .sh-only repo: config untouched" "$(jq -c . "$shg/.claude/kit.config.json")" '{"project":{"name":"s"}}'
  t "graft on a .sh-only repo: no rule, no consent, nothing else" "$(cd "$shg" && find . -type f | sort | tr '\n' ' ')" "./.claude/kit.config.json ./scripts/run.sh "
  # a repo with a .ts file, dry-run: the install + wire plan is printed and nothing is written
  tsg="$ws/ts-graft"; mkdir -p "$tsg/.claude" "$tsg/src"; : > "$tsg/src/a.ts"
  printf '%s\n' '{"project":{"name":"t"}}' > "$tsg/.claude/kit.config.json"
  out="$(KIT_DRY_RUN=1 "$ADD" graft --dir "$tsg" 2>&1)"; t "graft dry-run rc" "$?" "0"
  has "graft dry-run: npm is candidate 1"  "$out" "1. npm install -g @nanonets/graft"
  has "graft dry-run: pnpm is candidate 2" "$out" "2. pnpm add -g @nanonets/graft"
  has "graft dry-run: the wire command"    "$out" "graft init --agents claude --no-statusline --no-global"
  has "graft dry-run: names the rule it would write" "$out" "would write $tsg/.claude/rules/code-retrieval.md"
  t "graft dry-run: nothing written" "$(cd "$tsg" && find . -type f | sort | tr '\n' ' ')" "./.claude/kit.config.json ./src/a.ts "
  # declining writes no rule
  "$ADD" graft --dir "$tsg" --set enable=no >/dev/null 2>&1
  t "graft declined: no rule" "$([ -e "$tsg/.claude/rules/code-retrieval.md" ] && echo made || echo none)" "none"
  # a real add: the key and the rule, and still no install
  out="$("$ADD" graft --dir "$tsg" 2>&1)"; t "graft add rc" "$?" "0"
  t "graft add: the key" "$(jq -r .codeGraph.provider "$tsg/.claude/kit.config.json")" "graft"
  t "graft add: the rule is the template, verbatim" "$(cmp -s "$dir/../templates/rules/code-retrieval.md" "$tsg/.claude/rules/code-retrieval.md" && echo same || echo differs)" "same"
  t "graft add: writes the config and the rule, nothing else" "$(cd "$tsg" && find . -type f | sort | tr '\n' ' ')" "./.claude/kit.config.json ./.claude/rules/code-retrieval.md ./src/a.ts "
  has "graft add: says nothing was installed" "$out" "Nothing was installed."
  # a second run keeps an edited rule, and restores a deleted one
  echo "# local edit" >> "$tsg/.claude/rules/code-retrieval.md"
  "$ADD" graft --dir "$tsg" >/dev/null 2>&1
  t "second add keeps an edited rule" "$(tail -1 "$tsg/.claude/rules/code-retrieval.md")" "# local edit"
  rm -f "$tsg/.claude/rules/code-retrieval.md"
  "$ADD" graft --dir "$tsg" >/dev/null 2>&1
  t "second add restores a missing rule" "$([ -f "$tsg/.claude/rules/code-retrieval.md" ] && echo yes || echo no)" "yes"
  rm -f "$reg/graft.json"

  # --- on by default (#451): the shipped lavish descriptor. Declining is the one case that
  # writes — the off value — and it writes no rule; switching it back on restores the default.
  cp "$dir/../integrations/lavish.json" "$reg/lavish.json"
  lv="$ws/lavish-proj"; mkdir -p "$lv/.claude"
  printf '{"project":{"name":"l"}}\n' > "$lv/.claude/kit.config.json"
  t "lavish: listed as enabled with no key in the config" \
    "$( (cd "$lv" && CCKIT_OUTPUT=json "$ADD" 2>/dev/null) | jq -c '.integrations[] | select(.id == "lavish") | [.key, .enabled]')" '["reviewPages.enabled",true]'
  out="$(KIT_DRY_RUN=1 "$ADD" lavish --dir "$lv" --set enable=no 2>&1)"; t "lavish off dry-run rc" "$?" "0"
  t "lavish off dry-run: nothing written" "$(jq -c . "$lv/.claude/kit.config.json")" '{"project":{"name":"l"}}'
  t "lavish off dry-run: no rule is announced" "$(printf '%s' "$out" | grep -c 'review-pages.md')" "0"
  out="$("$ADD" lavish --dir "$lv" --set enable=no 2>&1)"; t "lavish off rc" "$?" "0"
  t "lavish off: the config records false" "$(jq -c .reviewPages "$lv/.claude/kit.config.json")" '{"enabled":false}'
  has "lavish off: says it is off and how to turn it on" "$out" "Lavish is off: reviewPages.enabled = false. Turn it back on with 'cckit add lavish'."
  t "lavish off: no rule written" "$([ -e "$lv/.claude/rules/review-pages.md" ] && echo made || echo none)" "none"
  t "lavish off: listed as not enabled" \
    "$( (cd "$lv" && CCKIT_OUTPUT=json "$ADD" 2>/dev/null) | jq -c '.integrations[] | select(.id == "lavish") | .enabled')" 'false'
  out="$("$ADD" lavish --dir "$lv" 2>&1)"; t "lavish on rc" "$?" "0"
  t "lavish on: the config records true" "$(jq -c .reviewPages "$lv/.claude/kit.config.json")" '{"enabled":true}'
  t "lavish on: the rule is the template, verbatim" "$(cmp -s "$dir/../templates/rules/review-pages.md" "$lv/.claude/rules/review-pages.md" && echo same || echo differs)" "same"
  has "lavish on: the attribution notice" "$out" "cckit is not affiliated with its author"
  rm -f "$reg/lavish.json"

  # a module wins a name it shares with an integration
  desc software '{"key":"codeGraph.provider","value":"clash"}' null
  mkdir -p "$ws/clash"
  "$ADD" software --dir "$ws/clash" >/dev/null 2>&1
  t "module wins a shared name" "$(jq -c .modules "$ws/clash/.claude/kit.config.json" 2>/dev/null)" '["software"]'
  rm -f "$reg/software.json"
  unset KIT_INTEGRATIONS_DIR

  # --- qa module (#294): `kit-add.sh qa --answers F` writes the qa block; a 2nd run is a no-op ---
  printf '%s\n' '{"command":"pnpm dev:stack","ports":"WEB_PORT=3000, API_PORT=4000","readiness":"WEB_PORT=/, API_PORT=/health","route":"/dashboard","credentialEnv":"QA_EMAIL, QA_PASSWORD"}' > "$ws/qa.json"
  "$ADD" qa --dir "$ws/myapp" --answers "$ws/qa.json" >/dev/null 2>&1; t "qa add rc" "$?" "0"
  t "qa block"         "$(jq -c .qa "$cfg")" '{"command":"pnpm dev:stack","ports":[{"env":"WEB_PORT","base":3000},{"env":"API_PORT","base":4000}],"readiness":[{"env":"WEB_PORT","path":"/"},{"env":"API_PORT","path":"/health"}],"route":"/dashboard","credentialEnv":["QA_EMAIL","QA_PASSWORD"]}'
  t "qa stacks on software" "$(jq -c .modules "$cfg")" '["qa","software"]'
  t "qa keeps software answers" "$(jq -r .deploy.target "$cfg")" "vercel"
  before="$(cat "$cfg")"
  "$ADD" qa --dir "$ws/myapp" --answers "$ws/qa.json" >/dev/null 2>&1; t "qa 2nd run rc" "$?" "0"
  t "qa 2nd run no-op" "$(cat "$cfg")" "$before"
  # a credential VALUE never reaches the config: the add fails and the file is untouched
  printf '%s\n' '{"command":"pnpm dev:stack","credentialEnv":"QA_PASSWORD=hunter2-value"}' > "$ws/qa-leak.json"
  "$ADD" qa --dir "$ws/myapp" --answers "$ws/qa-leak.json" >/dev/null 2>&1; t "qa value refused rc" "$?" "1"
  t "qa value refused: file untouched" "$(cat "$cfg")" "$before"
  # no stack command, no qa block (KIT_ASSUME_YES has no default to fall back on)
  bare="$(mktemp -d)"; mkdir -p "$bare/app"
  "$ADD" qa --dir "$bare/app" >/dev/null 2>&1; t "qa without a command rc" "$?" "1"
  t "qa without a command: no write" "$([ -f "$bare/app/.claude/kit.config.json" ] && echo wrote || echo clean)" "clean"
  # self-host layout: a root cckit.config.json is the config kit-add targets, not a second file.
  # That file pre-exists and is not manifest-tracked, so the conffiles guard applies: an unattended
  # run keeps it, and only an explicit yes on stdin writes.
  printf '%s\n' '{"project":{"name":"Self"}}' > "$bare/app/cckit.config.json"
  "$ADD" qa --dir "$bare/app" --answers "$ws/qa.json" >/dev/null 2>&1; t "qa self-host unattended rc" "$?" "0"
  t "qa self-host unattended: kept" "$(jq -c . "$bare/app/cckit.config.json")" '{"project":{"name":"Self"}}'
  printf 'y\n' | env -u KIT_ASSUME_YES "$ADD" qa --dir "$bare/app" --answers "$ws/qa.json" >/dev/null 2>&1; t "qa self-host confirmed rc" "$?" "0"
  t "qa self-host: root config" "$(jq -r '[.project.name, .qa.command] | join("|")' "$bare/app/cckit.config.json")" "Self|pnpm dev:stack"
  t "qa self-host: no scaffolded twin" "$([ -f "$bare/app/.claude/kit.config.json" ] && echo wrote || echo clean)" "clean"
  rm -rf "$bare"

  # ── a kit skill (#504): `add page-design` sets its key and copies the skill, no version bump ──
  unset KIT_INTEGRATIONS_DIR
  sk="$(mktemp -d)"; skc="$sk/.claude/kit.config.json"; mkdir -p "$sk/.claude"
  printf '%s\n' '{"kitVersion":"9.9.9","adapters":["claude","codex"],"tasks":{"default":"light"},"project":{"name":"P"}}' > "$skc"
  has "skill: listed" "$(cd "$sk" && "$ADD" 2>/dev/null)" "page-design"
  t "skill: list --llm before" "$(cd "$sk" && "$CCKIT" add --llm 2>/dev/null | jq -c '.skills[] | select(.id=="page-design") | [.key,.enabled,.installed]')" '["tasks.design",false,false]'
  KIT_DRY_RUN=1 "$ADD" page-design --dir "$sk" >/dev/null 2>&1; t "skill dry-run rc" "$?" "0"
  t "skill dry-run: nothing written" "$(cd "$sk" && find . -type f | LC_ALL=C sort | tr '\n' ' ')|$(jq -r '.tasks.design // "unset"' "$skc")" "./.claude/kit.config.json |unset"
  "$ADD" page-design --dir "$sk" >/dev/null 2>&1; t "skill add rc" "$?" "0"
  t "skill: key set, others kept" "$(jq -c '[.tasks.design, .tasks.default, .kitVersion, .project.name]' "$skc")" '[true,"light","9.9.9","P"]'
  t "skill: copied for each adapter, add.json left behind" "$(cd "$sk" && find .claude/skills .agents/skills -type f | LC_ALL=C sort | tr '\n' ' ')" \
    ".agents/skills/page-design/SKILL.md .agents/skills/page-design/references/design-file-template.md .agents/skills/page-design/references/generic-page-patterns.md .agents/skills/page-design/references/minimum-rules.md .claude/skills/page-design/SKILL.md .claude/skills/page-design/references/design-file-template.md .claude/skills/page-design/references/generic-page-patterns.md .claude/skills/page-design/references/minimum-rules.md "
  t "skill: the copy is the template" "$(cmp -s "$sk/.claude/skills/page-design/SKILL.md" "$dir/../templates/skills/page-design/SKILL.md" && echo same)" "same"
  t "skill: list --llm after" "$(cd "$sk" && "$CCKIT" add --llm 2>/dev/null | jq -c '.skills[] | select(.id=="page-design") | [.enabled,.installed]')" '[true,true]'
  # a copy the project edited is kept; a copy missing for one adapter is restored
  echo "edited by the project" > "$sk/.claude/skills/page-design/SKILL.md"; rm -rf "$sk/.agents/skills/page-design"
  snap="$(cat "$skc")"
  "$ADD" page-design --dir "$sk" >/dev/null 2>&1; t "skill re-run rc" "$?" "0"
  t "skill re-run: the edited copy is kept" "$(cat "$sk/.claude/skills/page-design/SKILL.md")" "edited by the project"
  t "skill re-run: the missing adapter copy is written" "$([ -f "$sk/.agents/skills/page-design/SKILL.md" ] && echo yes)" "yes"
  t "skill re-run: config byte-identical" "$(cat "$skc")" "$snap"
  # a claude-only project gets no .agents tree; a folder with no config is refused
  sk2="$(mktemp -d)"; mkdir -p "$sk2/.claude"; printf '%s\n' '{"kitVersion":"9.9.9"}' > "$sk2/.claude/kit.config.json"
  "$ADD" page-design --dir "$sk2" >/dev/null 2>&1
  t "skill: claude-only project" "$([ -f "$sk2/.claude/skills/page-design/SKILL.md" ] && echo yes)|$([ -e "$sk2/.agents" ] && echo agents || echo none)" "yes|none"
  sk3="$(mktemp -d)"
  out="$("$ADD" page-design --dir "$sk3" 2>&1)"; t "skill: no config rc" "$?" "1"
  has "skill: no config names init" "$out" "cckit init"
  t "skill: no config writes nothing" "$(find "$sk3" -type f | wc -l | tr -d ' ')" "0"
  rm -rf "$sk" "$sk2" "$sk3"

  [ "$fail" -eq 0 ] && echo "ALL OK($KIT_ADD_TEST_INNER)"
  exit "$fail"
fi

rc=0; ran=0
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || continue
  ran=$((ran+1)); echo "--- $sh ---"
  rcflag=""; [ "$sh" = "zsh" ] && rcflag="--no-rcs"
  KIT_ADD_TEST_INNER="$sh" PATH="$PATH" "$sh" $rcflag "$0" || rc=1
done
[ "$ran" -eq 0 ] && { echo "no shell"; exit 1; }
exit "$rc"
