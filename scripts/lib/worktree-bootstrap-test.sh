#!/bin/sh
# worktree-bootstrap-test.sh — the bootstrap dependency-install contract (#255), under bash AND zsh.
#
# The bug: wt_bootstrap ran `pnpm install` at the worktree ROOT unconditionally. Where the root
# manifest declares no dependencies (cckit itself is a published bash CLI — zero deps, zero scripts)
# pnpm resolves nothing but still writes a 9-line `pnpm-lock.yaml` with an empty `.: {}` importer.
# That stray lockfile then trips the captain's OWN lockfile policy floor and holds the PR for human
# review — cckit's bootstrap creating a file cckit's gate blocks.
#
# The bar: `pnpm install` runs exactly where the project actually declares dependencies — and the
# decision comes from the manifest, never from a hardcoded layout, because other repos use this kit.
#
# Run:  bash scripts/lib/worktree-bootstrap-test.sh
# Without args: re-runs itself under every available shell. With WBT_INNER set: runs the assertions
# in the current interpreter.
# errors: strict — a test runner: rc 1 on any failed assertion

dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

if [ -n "${WBT_INNER:-}" ]; then
  . "$dir/worktree-start.sh"
  fail=0
  n=0
  ok()  { n=$((n+1)); }
  bad() { n=$((n+1)); echo "FAIL($WBT_INNER): $1"; fail=1; }

  tmp=$(mktemp -d 2>/dev/null || mktemp -d -t wbt)
  trap 'rm -rf "$tmp"' EXIT INT TERM

  # A stub `pnpm` that does exactly the one thing that matters here: writes a lockfile in its cwd,
  # the way real pnpm does. Put first on PATH so wt_bootstrap finds it instead of any real pnpm —
  # the test must not depend on a network, a registry, or pnpm being installed at all.
  mkdir -p "$tmp/bin"
  cat > "$tmp/bin/pnpm" <<'STUB'
#!/bin/sh
printf "lockfileVersion: '9.0'\n\nimporters:\n\n  .: {}\n" > pnpm-lock.yaml
mkdir -p node_modules
exit 0
STUB
  chmod +x "$tmp/bin/pnpm"
  PATH="$tmp/bin:$PATH"; export PATH

  # fixture <name> <package.json-body> — a bare project dir; echoes its path.
  fixture() {
    d="$tmp/$1"; mkdir -p "$d"; printf '%s\n' "$2" > "$d/package.json"; printf '%s\n' "$d"
  }

  # targets <dir> — wt_install_targets output as a single space-joined string ('-' when empty), so
  # an assertion reads as one comparison in both shells.
  targets() { out=$(wt_install_targets "$1" | tr '\n' ' ' | sed 's/ *$//'); [ -n "$out" ] || out='-'; printf '%s\n' "$out"; }

  # ── wt_install_targets: what the manifest says, nothing else ────────────────────────────────
  # 1. A dependency-free root — cckit's own shape. Nothing to install.
  bare=$(fixture bare '{"name":"bare","version":"1.0.0","bin":{"x":"bin/x"}}')
  [ "$(targets "$bare")" = "-" ] || bad "dependency-free root should have no install target, got '$(targets "$bare")'"
  ok

  # 2. Empty dependency blocks are still no dependencies (pnpm would resolve nothing).
  empty=$(fixture empty '{"name":"empty","dependencies":{},"devDependencies":{}}')
  [ "$(targets "$empty")" = "-" ] || bad "empty dependency blocks should have no install target, got '$(targets "$empty")'"
  ok

  # 3. A root that DOES declare deps still installs — the fix must not break real projects.
  deps=$(fixture deps '{"name":"deps","dependencies":{"left-pad":"^1.3.0"}}')
  [ "$(targets "$deps")" = "." ] || bad "root with dependencies should install at '.', got '$(targets "$deps")'"
  ok

  # 4. devDependencies alone are enough.
  dev=$(fixture dev '{"name":"dev","devDependencies":{"vitest":"^1.0.0"}}')
  [ "$(targets "$dev")" = "." ] || bad "root with devDependencies should install at '.', got '$(targets "$dev")'"
  ok

  # 5. A pnpm workspace root installs even with no deps of its own — the MEMBERS hold them.
  ws=$(fixture ws '{"name":"ws","private":true}')
  printf 'packages:\n  - "apps/*"\n' > "$ws/pnpm-workspace.yaml"
  [ "$(targets "$ws")" = "." ] || bad "pnpm workspace root should install at '.', got '$(targets "$ws")'"
  ok

  # 6. A settings-only pnpm-workspace.yaml (pnpm 10 overrides/onlyBuiltDependencies, no `packages:`)
  #    is NOT a member-bearing workspace — cckit's docs-site has exactly this file.
  set_only=$(fixture setonly '{"name":"setonly"}')
  printf 'onlyBuiltDependencies:\n  - sharp\noverrides:\n  esbuild: ">=0.28.1"\n' > "$set_only/pnpm-workspace.yaml"
  [ "$(targets "$set_only")" = "-" ] || bad "settings-only pnpm-workspace.yaml is not a workspace root, got '$(targets "$set_only")'"
  ok

  # 7. npm/yarn `workspaces` in package.json counts too.
  nws=$(fixture nws '{"name":"nws","private":true,"workspaces":["packages/*"]}')
  [ "$(targets "$nws")" = "." ] || bad "npm workspaces root should install at '.', got '$(targets "$nws")'"
  ok

  # ── a workspace declaration with NO MEMBERS is not a workspace root ─────────────────────────
  # The `packages:` KEY alone is not enough. An empty member list leaves pnpm nothing to resolve,
  # so it writes only the empty-importer lockfile — the #255 symptom, re-created through the
  # workspace branch instead of the dependency branch.
  ws0=$(fixture ws0 '{"name":"ws0"}')
  printf 'packages: []\n' > "$ws0/pnpm-workspace.yaml"
  [ "$(targets "$ws0")" = "-" ] || bad "'packages: []' declares no members — should not install, got '$(targets "$ws0")'"
  ok

  wsb=$(fixture wsb '{"name":"wsb"}')
  printf 'packages:\nonlyBuiltDependencies:\n  - sharp\n' > "$wsb/pnpm-workspace.yaml"
  [ "$(targets "$wsb")" = "-" ] || bad "an empty 'packages:' block declares no members, got '$(targets "$wsb")'"
  ok

  # …but the inline flow-sequence form with a real pattern still counts.
  wsi=$(fixture wsi '{"name":"wsi"}')
  printf 'packages: ["apps/*", "libs/*"]\n' > "$wsi/pnpm-workspace.yaml"
  [ "$(targets "$wsi")" = "." ] || bad "inline 'packages: [\"apps/*\"]' is a workspace root, got '$(targets "$wsi")'"
  ok

  # The same three empty shapes on the package.json side.
  jw0=$(fixture jw0 '{"name":"jw0","workspaces":[]}')
  [ "$(targets "$jw0")" = "-" ] || bad "'workspaces: []' declares no members, got '$(targets "$jw0")'"
  ok

  jwo=$(fixture jwo '{"name":"jwo","workspaces":{}}')
  [ "$(targets "$jwo")" = "-" ] || bad "'workspaces: {}' declares no members, got '$(targets "$jwo")'"
  ok

  jwp=$(fixture jwp '{"name":"jwp","workspaces":{"nohoist":["x"],"packages":[]}}')
  [ "$(targets "$jwp")" = "-" ] || bad "'workspaces.packages: []' declares no members, got '$(targets "$jwp")'"
  ok

  # …and the yarn object form WITH members still counts.
  jwm=$(fixture jwm '{"name":"jwm","workspaces":{"packages":["packages/*"]}}')
  [ "$(targets "$jwm")" = "." ] || bad "'workspaces.packages: [\"packages/*\"]' is a workspace root, got '$(targets "$jwm")'"
  ok

  # 8. `.worktree.installPaths` wins outright — the generic knob for repos whose Node project lives
  #    in a subdirectory (cckit's own `docs-site/`). No project layout is hardcoded in the kit.
  if command -v jq >/dev/null 2>&1; then
    sub=$(fixture sub '{"name":"sub"}')
    mkdir -p "$sub/.claude" "$sub/docs-site"
    printf '{"worktree":{"installPaths":["docs-site"]}}\n' > "$sub/.claude/kit.config.json"
    printf '{"name":"docs","dependencies":{"astro":"^5"}}\n' > "$sub/docs-site/package.json"
    [ "$(targets "$sub")" = "docs-site" ] || bad "installPaths should scope the install, got '$(targets "$sub")'"
    ok

    # 8b. An empty installPaths array is an explicit "install nothing".
    none=$(fixture none '{"name":"none","dependencies":{"left-pad":"^1"}}')
    printf '{"worktree":{"installPaths":[]}}\n' > "$none/cckit.config.json"
    [ "$(targets "$none")" = "-" ] || bad "installPaths [] should install nothing, got '$(targets "$none")'"
    ok

    # ── installPaths must never escape the worktree ────────────────────────────────────────────
    # A worktree sits at <root>/.claude/worktrees/<kind>+<N>-<slug>, three levels under the primary
    # checkout — which is SHARED and may have another session's work parked on it. A `../../..`
    # entry that reached the `cd` would run pnpm in that tree. Config is input; it gets validated.
    mkdir -p "$tmp/victim/inner/esc"
    printf '{"name":"VICTIM","dependencies":{"left-pad":"^1"}}\n' > "$tmp/victim/package.json"
    printf '{"name":"esc"}\n' > "$tmp/victim/inner/esc/package.json"
    mkdir -p "$tmp/victim/inner/esc/.claude"
    esc="$tmp/victim/inner/esc"

    printf '{"worktree":{"installPaths":["../.."]}}\n' > "$esc/.claude/kit.config.json"
    [ "$(targets "$esc" 2>/dev/null)" = "-" ] || bad "'../..' should be refused, got '$(targets "$esc" 2>/dev/null)'"
    wt_bootstrap "$esc" "$esc" 255 >/dev/null 2>&1
    [ -f "$tmp/victim/pnpm-lock.yaml" ] && bad "traversal escaped the worktree — pnpm ran OUTSIDE it"
    ok; ok

    # An absolute path is never a worktree-relative target.
    printf '{"worktree":{"installPaths":["%s"]}}\n' "$tmp/victim" > "$esc/.claude/kit.config.json"
    [ "$(targets "$esc" 2>/dev/null)" = "-" ] || bad "an absolute installPaths entry should be refused"
    ok

    # A path that climbs and comes back is fine — it stays inside. It normalizes on the way out.
    mkdir -p "$esc/docs-site"
    printf '{"name":"d","dependencies":{"astro":"^5"}}\n' > "$esc/docs-site/package.json"
    printf '{"worktree":{"installPaths":["./docs-site/../docs-site/"]}}\n' > "$esc/.claude/kit.config.json"
    [ "$(targets "$esc" 2>/dev/null)" = "docs-site" ] || bad "a contained path should normalize to 'docs-site', got '$(targets "$esc" 2>/dev/null)'"
    ok

    # A symlink out of the tree is the escape the lexical check alone cannot see.
    if ln -s "$tmp/victim" "$esc/link-out" 2>/dev/null; then
      printf '{"worktree":{"installPaths":["link-out"]}}\n' > "$esc/.claude/kit.config.json"
      [ "$(targets "$esc" 2>/dev/null)" = "-" ] || bad "a symlink pointing outside the worktree should be refused"
      wt_bootstrap "$esc" "$esc" 255 >/dev/null 2>&1
      [ -f "$tmp/victim/pnpm-lock.yaml" ] && bad "symlink escape let pnpm run OUTSIDE the worktree"
      ok; ok
    fi
  fi

  # ── wt_bootstrap end to end: does a root pnpm-lock.yaml appear? ─────────────────────────────
  # The regression itself. Root and worktree are the same fixture dir: the env-copy step is then a
  # no-op and the install step is what is under test.
  wt_bootstrap "$bare" "$bare" 255 >/dev/null 2>&1
  [ -f "$bare/pnpm-lock.yaml" ] && bad "wt_bootstrap planted a root pnpm-lock.yaml in a dependency-free project (#255)"
  ok

  # …and the other half of the bar: a project WITH root deps still gets its install.
  wt_bootstrap "$deps" "$deps" 255 >/dev/null 2>&1
  [ -f "$deps/pnpm-lock.yaml" ] || bad "wt_bootstrap skipped the install for a project that DOES declare dependencies"
  ok

  # The existing escape hatch still wins over everything.
  KIT_WT_INSTALL=0 wt_bootstrap "$dev" "$dev" 255 >/dev/null 2>&1
  [ -f "$dev/pnpm-lock.yaml" ] && bad "KIT_WT_INSTALL=0 no longer skips the install"
  ok

  # Scoped install lands in the subdirectory and NOT at the root.
  if command -v jq >/dev/null 2>&1; then
    wt_bootstrap "$sub" "$sub" 255 >/dev/null 2>&1
    [ -f "$sub/docs-site/pnpm-lock.yaml" ] || bad "scoped install did not run in docs-site"
    [ -f "$sub/pnpm-lock.yaml" ] && bad "scoped install still planted a ROOT pnpm-lock.yaml"
    ok; ok
  fi

  [ "$fail" -eq 0 ] && echo "OK($WBT_INNER): $n cases"
  exit "$fail"
fi

rc=0
ran=0
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || continue
  ran=1
  WBT_INNER="$sh" "$sh" "$0" || rc=1
done
[ "$ran" -eq 1 ] || { echo "no bash/zsh found"; exit 1; }
exit "$rc"
