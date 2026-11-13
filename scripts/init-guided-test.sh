#!/usr/bin/env bash
# shellcheck shell=bash
# init-guided-test.sh — the guided `cckit init` (#456), end to end and offline.
#
# Covers every detection branch (home directory, missing / empty folder, files without a project
# marker, a project without git, a git repository without a remote, a repository with a remote),
# the answers file, the one confirmation (--yes; no terminal without it), --dry-run writing
# nothing, --no-github, an idempotent re-run, a refused branch protection, a failed step that does
# not hide the later ones, and --upgrade staying out of the flow.
#
# Hermetic: HOME is a temp dir, `gh` and `pnpm` are stubs on PATH, "GitHub" is a directory of bare
# repositories plus a log of every write the stub was asked to make, and the recipe is a fixture
# whose commands are plain shell. Nothing here reaches the network or a real repository.
# Run:  bash scripts/init-guided-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/scripts/lib/test-env.sh" && test_env_seal
INIT="$ROOT/scripts/init.sh"
fail=0
t()     { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
has()   { if grep -qF -- "$3" <<<"$2"; then echo "ok: $1"; else echo "FAIL: $1 -> '$3' not in output:"; printf '%s\n' "$2" | tail -25; fail=1; fi; }
hasnt() { if grep -qF -- "$3" <<<"$2"; then echo "FAIL: $1 -> '$3' found in output"; fail=1; else echo "ok: $1"; fi; }
yes_if() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1 -> not true: $2"; fail=1; fi; }

for dep in jq git perl; do
  command -v "$dep" >/dev/null 2>&1 || { echo "init-guided-test: $dep absent — skipping (dependency-light gate)"; exit 0; }
done

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
tmp="$(cd "$tmp" && pwd -P)"
export HOME="$tmp/home"; mkdir -p "$HOME"
printf '[user]\n\tname = Test Person\n\temail = test@example.com\n[init]\n\tdefaultBranch = trunk\n' > "$HOME/.gitconfig"
export GHS="$tmp/github"; mkdir -p "$GHS/git" "$GHS/repos"; : > "$GHS/writes.log"

# ── stubs ────────────────────────────────────────────────────────────────────────────────────────
mkdir -p "$tmp/stubs"
cat > "$tmp/stubs/gh" <<'STUB'
#!/usr/bin/env bash
# A GitHub made of files: $GHS/repos/<owner>__<name>/ holds one repository's state, $GHS/git/ the
# bare repositories git pushes to, $GHS/writes.log one line per write the caller asked for.
set -u
log() { printf '%s\n' "$*" >> "$GHS/writes.log"; }
rdir() { printf '%s/repos/%s\n' "$GHS" "$(printf '%s' "$1" | tr '/' '_' | sed 's/_/__/')"; }
here_repo() {  # the repository the cwd's origin points at, when it is one of ours
  local u; u="$(git remote get-url origin 2>/dev/null)" || return 1
  case "$u" in "$GHS/git/"*) u="${u#"$GHS/git/"}"; printf '%s\n' "${u%.git}" ;; *) return 1 ;; esac
}
case "${1:-} ${2:-}" in
  "auth status") exit 0 ;;
  "config get") echo https; exit 0 ;;
  "api user") echo tester; exit 0 ;;
  "repo view")
    shift 2; repo=""; fields=""
    while [ $# -gt 0 ]; do case "$1" in --json) fields="$2"; shift 2 ;; -q|--jq) shift 2 ;; *) repo="$1"; shift ;; esac; done
    [ -n "$repo" ] || repo="$(here_repo)" || exit 1
    d="$(rdir "$repo")"; [ -d "$d" ] || { echo "GraphQL: Could not resolve to a Repository" >&2; exit 1; }
    case "$fields" in
      nameWithOwner) echo "$repo" ;;
      defaultBranchRef) cat "$d/default" 2>/dev/null || echo main ;;
      url,sshUrl) printf '%s\t%s\n' "$GHS/git/$repo" "" ;;
    esac
    exit 0 ;;
  "repo create")
    shift 2; repo="$1"; shift; vis=""; src=""
    while [ $# -gt 0 ]; do case "$1" in --private|--public) vis="$1"; shift ;; --source) src="$2"; shift 2 ;; --remote) shift 2 ;; *) shift ;; esac; done
    [ -f "$GHS/fail-create" ] && { echo "gh: could not create the repository (HTTP 500)" >&2; exit 1; }
    log "repo create $repo $vis"
    d="$(rdir "$repo")"; mkdir -p "$d" "$GHS/git/$(dirname "$repo")"
    git init -q --bare "$GHS/git/$repo.git"
    git -C "$src" remote add origin "$GHS/git/$repo.git"
    exit 0 ;;
  "repo edit")
    repo="$3"; log "repo edit $*"; printf '%s\n' "$5" > "$(rdir "$repo")/default"; exit 0 ;;
  "label list")
    shift 2; while [ $# -gt 0 ]; do case "$1" in --repo) repo="$2"; shift 2 ;; *) shift ;; esac; done
    cat "$(rdir "$repo")/labels" 2>/dev/null; exit 0 ;;
  "label create")
    name="$3"; shift 3; while [ $# -gt 0 ]; do case "$1" in --repo) repo="$2"; shift 2 ;; *) shift ;; esac; done
    [ -f "$GHS/fail-labels" ] && { echo "gh: label could not be created (HTTP 500)" >&2; exit 1; }
    log "label create $repo $name"; printf '%s\n' "$name" >> "$(rdir "$repo")/labels"; exit 0 ;;
  "api graphql") exit 1 ;;
esac
if [ "${1:-}" = "api" ]; then
  shift; method=GET; ep=""; title=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -X) method="$2"; shift 2 ;;
      -f) case "$2" in title=*) title="${2#title=}"; method=POST ;; esac; shift 2 ;;
      -F|--jq|-q|--input) shift 2 ;;
      *) ep="$1"; shift ;;
    esac
  done
  case "$ep" in
    repos/*/*/milestones*)
      repo="$(printf '%s' "$ep" | cut -d/ -f2-3)"; d="$(rdir "$repo")"
      if [ "$method" = POST ]; then log "milestone create $repo $title"; printf '%s\n' "$title" >> "$d/milestones"; else cat "$d/milestones" 2>/dev/null; fi
      exit 0 ;;
    repos/*/*/branches/*/protection)
      repo="$(printf '%s' "$ep" | cut -d/ -f2-3)"; d="$(rdir "$repo")"; br="$(printf '%s' "$ep" | cut -d/ -f5)"
      if [ -f "$GHS/plan-refuses" ]; then echo "gh: Upgrade to GitHub Pro or make this repository public to enable this feature. (HTTP 403)" >&2; exit 1; fi
      if [ "$method" = PUT ]; then cat >/dev/null; log "protect $repo $br"; : > "$d/protected-$br"; echo '{}'; exit 0; fi
      [ -f "$d/protected-$br" ] && { echo '{}'; exit 0; }
      echo "gh: Branch not protected (HTTP 404)" >&2; exit 1 ;;
    repos/*/*)
      repo="$(printf '%s' "$ep" | cut -d/ -f2-3)"; d="$(rdir "$repo")"
      if [ "$method" = PATCH ]; then log "repo patch $repo delete_branch_on_merge"; echo true > "$d/delete-on-merge"; exit 0; fi
      cat "$d/delete-on-merge" 2>/dev/null || echo false
      exit 0 ;;
  esac
fi
echo "stub gh: unhandled: $*" >&2
exit 1
STUB
# pnpm: the database option's install command. Adds each named package to package.json.
cat > "$tmp/stubs/pnpm" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = "add" ] || { echo "stub pnpm: unhandled: $*" >&2; exit 1; }
shift
for p in "$@"; do
  jq --arg p "$p" '.dependencies[$p] = "0.0.0-stub"' package.json > package.json.tmp && mv package.json.tmp package.json
done
STUB
chmod +x "$tmp/stubs/gh" "$tmp/stubs/pnpm"
export PATH="$tmp/stubs:$PATH"

# A fixture recipe: plain shell, no network. That init runs it is the proof that a recipe is data —
# the verb names no recipe id.
fx="$tmp/recipes"; mkdir -p "$fx"
cat > "$fx/demo.json" <<'JSON'
{
  "id": "demo", "label": "Demo app", "summary": "A fixture.", "recommended": true,
  "profile": "minimal", "stack": "nextjs", "folderName": "^[a-z0-9][a-z0-9._-]*$",
  "requires": [{ "command": "jq", "why": "fixture" }],
  "steps": [
    { "label": "Write the app", "run": "printf '{\"name\":\"demo\",\"dependencies\":{\"next\":\"1.0.0\"}}\\n' > package.json && mkdir -p app && echo page > app/page.tsx" },
    { "label": "Ignore env files", "run": "printf '.env*\\n' > .gitignore" }
  ],
  "start": "pnpm dev", "lastVerified": "2026-11-12"
}
JSON
export KIT_RECIPES_DIR="$fx"
export KIT_INIT_PREFLIGHT=0 KIT_INIT_BROWSER=0 KIT_INIT_TTY=0 KIT_ASCII=1 NO_COLOR=1

run() {  # run <cwd> <init args…> -> OUT, RC
  local d="$1"; shift
  OUT="$(cd "$d" && CLAUDE_PLUGIN_ROOT="$ROOT" bash "$INIT" "$@" 2>&1)"; RC=$?
}
writes() { wc -l < "$GHS/writes.log" | tr -d ' '; }
tree_sum() {  # a checksum of every file outside .git
  ( cd "$1" && find . -type f ! -path './.git/*' -print0 | sort -z | xargs -0 cksum | cksum )
}

# ── 1. detection ────────────────────────────────────────────────────────────────────────────────
# shellcheck source=/dev/null
. "$ROOT/scripts/lib/init-guide.sh"
mkdir -p "$tmp/d/empty" "$tmp/d/files" "$tmp/d/proj" "$tmp/d/gitno" "$tmp/d/gitre" "$HOME/Documents"
echo notes > "$tmp/d/files/notes.txt"; : > "$tmp/d/empty/.DS_Store"
echo '{}' > "$tmp/d/proj/package.json"
git -C "$tmp/d/gitno" init -q
git -C "$tmp/d/gitre" init -q; git -C "$tmp/d/gitre" remote add origin "https://github.com/tester/gitre.git"
t "detect: home directory"            "$(init_detect_class "$HOME")"            "home"
t "detect: ~/Documents"               "$(init_detect_class "$HOME/Documents")"  "home"
t "detect: /"                         "$(init_detect_class /)"                  "home"
t "detect: a folder that is not there" "$(init_detect_class "$tmp/d/nope")"     "missing"
t "detect: empty (only .DS_Store)"    "$(init_detect_class "$tmp/d/empty")"     "empty"
t "detect: files, no marker"          "$(init_detect_class "$tmp/d/files")"     "files"
t "detect: project marker, no git"    "$(init_detect_class "$tmp/d/proj")"      "project-nogit"
t "detect: git, no remote"            "$(init_detect_class "$tmp/d/gitno")"     "git-noremote"
t "detect: git with a remote"         "$(init_detect_class "$tmp/d/gitre")"     "project-remote"
t "abs path of a missing nested folder" "$(init_abs_path "$tmp/d/a/b")"         "$tmp/d/a/b"

# ── 2. home directory ───────────────────────────────────────────────────────────────────────────
run "$HOME" --profile minimal
t   "home, no terminal, no answers: refused (rc 2)" "$RC" "2"
has "home: says it is not a project folder" "$OUT" "not a project folder"
yes_if "home: nothing was scaffolded into it" '[ ! -e "$HOME/.claude" ] && [ ! -e "$HOME/CLAUDE.md" ] && [ ! -e "$HOME/scripts" ]'

printf '{"new_project":"no"}\n' > "$tmp/a-no.json"
run "$HOME" --answers "$tmp/a-no.json" --yes
t   "home, 'not a new project': rc 0" "$RC" "0"
has "home, 'not a new project': says nothing was written" "$OUT" "Nothing was written"
yes_if "home, 'not a new project': nothing written" '[ ! -e "$HOME/.claude" ] && [ "$(writes)" = "0" ]'

printf '{"new_project":"yes","project_name":"My Shop","location":"here"}\n' > "$tmp/a-here.json"
run "$HOME" --answers "$tmp/a-here.json" --yes
t   "home, location 'here': refused (rc 2)" "$RC" "2"
yes_if "home, location 'here': nothing written" '[ ! -e "$HOME/.claude" ]'

# The whole path: home -> new project in its own folder -> recipe -> database -> kit -> GitHub.
printf '{"new_project":"yes","project_name":"My Shop","recipe":"demo","database_needed":"yes","database":"supabase"}\n' > "$tmp/a-new.json"
run "$HOME" --answers "$tmp/a-new.json" --yes
shop="$HOME/my-shop"
t   "new project from home: rc 0" "$RC" "0"
yes_if "new project: lives in its own folder, named from the answer" '[ -d "$shop" ]'
yes_if "new project: home itself got nothing" '[ ! -e "$HOME/.claude" ] && [ ! -e "$HOME/package.json" ]'
yes_if "new project: the recipe ran" '[ -f "$shop/app/page.tsx" ]'
yes_if "new project: the kit is installed" '[ -f "$shop/.claude/kit.config.json" ] && [ -f "$shop/CLAUDE.md" ]'
t   "new project: profile comes from the recipe" "$(jq -r .profile "$shop/.claude/kit.config.json")" "minimal"
t   "new project: base branch is develop" "$(jq -r .github.baseBranch "$shop/.claude/kit.config.json")" "develop"
t   "new project: repo is <login>/<slug>" "$(jq -r .github.repo "$shop/.claude/kit.config.json")" "tester/my-shop"
yes_if "database: client code is in the project" '[ -f "$shop/lib/supabase/client.ts" ] && [ -f "$shop/lib/supabase/server.ts" ]'
yes_if "database: env file names both variables" 'grep -q "^NEXT_PUBLIC_SUPABASE_URL=" "$shop/.env.local" && grep -q "^NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY=" "$shop/.env.local"'
yes_if "database: packages were added" 'jq -e ".dependencies | has(\"@supabase/ssr\") and has(\"@supabase/supabase-js\")" "$shop/package.json" >/dev/null'
has "database: the guide steps are printed (no browser)" "$OUT" "NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY = the publishable key"
has "database: the guide page is named" "$OUT" "databases/supabase/guide.html"
t   "git: one commit" "$(git -C "$shop" rev-list --count HEAD)" "1"
t   "git: the env file is not in the commit" "$(git -C "$shop" ls-files .env.local)" ""
t   "git: the working tree is clean after the first commit" "$(git -C "$shop" status --porcelain)" ""
t   "git: checked out on develop" "$(git -C "$shop" symbolic-ref --short HEAD)" "develop"
t   "GitHub: main and develop were pushed" "$(git -C "$GHS/git/tester/my-shop.git" for-each-ref --format='%(refname:short)' refs/heads | tr '\n' ' ')" "develop main "
has "GitHub: repository created PRIVATE" "$(cat "$GHS/writes.log")" "repo create tester/my-shop --private"
has "GitHub: default branch set to develop" "$(cat "$GHS/writes.log")" "--default-branch develop"
has "GitHub: head branches deleted on merge" "$(cat "$GHS/writes.log")" "repo patch tester/my-shop delete_branch_on_merge"
has "GitHub: develop protected" "$(cat "$GHS/writes.log")" "protect tester/my-shop develop"
has "GitHub: labels created" "$(cat "$GHS/writes.log")" "label create tester/my-shop priority:p1"
has "GitHub: milestones created" "$(cat "$GHS/writes.log")" "milestone create tester/my-shop"
has "report: the plan is listed before the steps" "$OUT" "Create the PRIVATE repository tester/my-shop"
has "report: totals" "$OUT" "0 failed"
hasnt "report: no secret placeholder value echoed as a step detail" "$OUT" "your-publishable-key"

# ── 3. idempotent re-run ────────────────────────────────────────────────────────────────────────
w0="$(writes)"; s0="$(tree_sum "$shop")"; h0="$(git -C "$shop" rev-parse HEAD)"
run "$shop" --yes
t   "re-run: rc 0" "$RC" "0"
t   "re-run: no GitHub write" "$(writes)" "$w0"
t   "re-run: no file changed" "$(tree_sum "$shop")" "$s0"
t   "re-run: no new commit" "$(git -C "$shop" rev-parse HEAD)" "$h0"
hasnt "re-run: no step reports done" "$OUT" "[done"
has "re-run: says the kit files are already there" "$OUT" "cckit files — already there"
has "re-run: says the labels are there" "$OUT" "labels — all"
run "$shop" --database supabase --yes
t   "re-run with --database: rc 0, still no write" "$RC:$(writes)" "0:$w0"
t   "re-run with --database: no file changed" "$(tree_sum "$shop")" "$s0"

run "$shop" --dry-run
t   "re-run --dry-run: rc 0, no write" "$RC:$(writes):$(tree_sum "$shop")" "0:$w0:$s0"
has "re-run --dry-run: says the kit files stay" "$OUT" "cckit files: already there"
has "re-run --dry-run: lists the setup steps" "$OUT" "Use the repository this folder is already connected to"

# ── 4. --upgrade is not part of the flow ────────────────────────────────────────────────────────
run "$shop" --upgrade --yes
hasnt "--upgrade: no project setup" "$OUT" "Project setup"
t   "--upgrade: no GitHub write" "$(writes)" "$w0"

# ── 5. empty folder, named on the command line ──────────────────────────────────────────────────
printf '{"recipe":"none","profile":"minimal"}\n' > "$tmp/a-empty.json"
: > "$GHS/writes.log"
run "$tmp" "$tmp/p/blank" --answers "$tmp/a-empty.json" --yes --public
t   "empty folder: rc 0" "$RC" "0"
has "empty folder: asked whether it is a new project" "$OUT" "Is this a new project?"
yes_if "empty folder: kit installed, no recipe" '[ -f "$tmp/p/blank/.claude/kit.config.json" ] && [ ! -f "$tmp/p/blank/package.json" ]'
has "--public: the repository is created public" "$(cat "$GHS/writes.log")" "repo create tester/blank --public"
t   "empty folder: git init used main, not the user's init.defaultBranch" "$(git -C "$GHS/git/tester/blank.git" for-each-ref --format='%(refname:short)' refs/heads | tr '\n' ' ')" "develop main "

# ── 6. files without a project marker ───────────────────────────────────────────────────────────
mkdir -p "$tmp/p/loose"; echo "my notes" > "$tmp/p/loose/notes.txt"
printf '{"folder_use":"cancel"}\n' > "$tmp/a-cancel.json"
run "$tmp/p/loose" --answers "$tmp/a-cancel.json" --yes
t   "files, cancel: rc 0, nothing written" "$RC:$(ls -A "$tmp/p/loose" | tr '\n' ' ')" "0:notes.txt "
printf '{"folder_use":"here","profile":"minimal"}\n' > "$tmp/a-here2.json"
run "$tmp/p/loose" --answers "$tmp/a-here2.json" --yes
t   "files, set up here: rc 0" "$RC" "0"
t   "files, set up here: the existing file is untouched" "$(cat "$tmp/p/loose/notes.txt")" "my notes"
yes_if "files, set up here: kit installed and committed" '[ -f "$tmp/p/loose/.claude/kit.config.json" ] && [ "$(git -C "$tmp/p/loose" rev-list --count HEAD)" = "1" ]'
printf '{"folder_use":"new","project_name":"Side Thing","profile":"minimal","recipe":"none"}\n' > "$tmp/a-new2.json"
mkdir -p "$tmp/p/loose2"; echo x > "$tmp/p/loose2/x.txt"
run "$tmp/p/loose2" --answers "$tmp/a-new2.json" --no-github
t   "files, new project elsewhere: rc 0" "$RC" "0"
yes_if "files, new project elsewhere: made in a sub-folder, the original left alone" '[ -f "$tmp/p/loose2/side-thing/.claude/kit.config.json" ] && [ ! -e "$tmp/p/loose2/.claude" ]'

# ── 7. git repository without a remote ──────────────────────────────────────────────────────────
mkdir -p "$tmp/p/local"; git -C "$tmp/p/local" init -q
echo hi > "$tmp/p/local/README.md"; git -C "$tmp/p/local" add -A; git -C "$tmp/p/local" commit -q -m first
: > "$GHS/writes.log"
run "$tmp/p/local" --profile minimal --yes
t   "git, no remote: rc 0" "$RC" "0"
has "git, no remote: first commit skipped" "$OUT" "first commit — the repository already has commits"
has "git, no remote: repository created" "$(cat "$GHS/writes.log")" "repo create tester/local --private"
t   "git, no remote: the existing commit is the only one" "$(git -C "$tmp/p/local" rev-list --count HEAD)" "1"
yes_if "git, no remote: develop is on GitHub" 'git -C "$GHS/git/tester/local.git" show-ref --verify -q refs/heads/develop'

# ── 8. repository that already has a GitHub remote ──────────────────────────────────────────────
mkdir -p "$GHS/repos/tester__adopted" "$GHS/git/tester" "$tmp/p/adopted"
git init -q --bare "$GHS/git/tester/adopted.git"
git -C "$tmp/p/adopted" init -q; git -C "$tmp/p/adopted" symbolic-ref HEAD refs/heads/main
echo hi > "$tmp/p/adopted/README.md"; git -C "$tmp/p/adopted" add -A; git -C "$tmp/p/adopted" commit -q -m first
git -C "$tmp/p/adopted" remote add origin "$GHS/git/tester/adopted.git"; git -C "$tmp/p/adopted" push -q -u origin main
: > "$GHS/writes.log"
run "$tmp/p/adopted" --profile minimal --yes
t   "existing remote: rc 0" "$RC" "0"
has "existing remote: adopted, not created" "$OUT" "GitHub repository — already connected to"
hasnt "existing remote: no repo create" "$(cat "$GHS/writes.log")" "repo create"
hasnt "existing remote: default branch not changed" "$(cat "$GHS/writes.log")" "repo edit"
t   "existing remote: base branch is the repository's own" "$(jq -r .github.baseBranch "$tmp/p/adopted/.claude/kit.config.json")" "main"
has "existing remote: the missing steps still run" "$(cat "$GHS/writes.log")" "protect"
t   "existing remote: the checkout was not moved" "$(git -C "$tmp/p/adopted" symbolic-ref --short HEAD)" "main"

# ── 9. --dry-run writes nothing ─────────────────────────────────────────────────────────────────
: > "$GHS/writes.log"
run "$tmp" "$tmp/p/dry" --profile minimal --recipe demo --database supabase --dry-run
t   "dry run: rc 0" "$RC" "0"
yes_if "dry run: the folder was not created" '[ ! -e "$tmp/p/dry" ]'
t   "dry run: no GitHub write" "$(writes)" "0"
has "dry run: lists the GitHub steps" "$OUT" "Create the PRIVATE repository tester/dry"
has "dry run: lists the recipe commands" "$OUT" "app/page.tsx"
has "dry run: lists the database files" "$OUT" "lib/supabase/client.ts"

# ── 10. no terminal and no --yes: the setup needs a confirmation it cannot get ──────────────────
run "$tmp" "$tmp/p/zzbravo" --profile minimal
t   "no --yes, no terminal: rc 0 (the files are written)" "$RC" "0"
has "no --yes, no terminal: says the setup did not run and how to run it" "$OUT" "cckit init --yes"
yes_if "no --yes, no terminal: no git repository, no GitHub write" '[ ! -e "$tmp/p/zzbravo/.git" ] && [ "$(writes)" = "0" ]'

# ── 11. --no-github is the scaffold-only run ────────────────────────────────────────────────────
run "$tmp" "$tmp/p/zzalpha" --profile minimal --no-github
t   "--no-github: rc 0" "$RC" "0"
yes_if "--no-github: no git repository, no GitHub write" '[ ! -e "$tmp/p/zzalpha/.git" ] && [ "$(writes)" = "0" ]'
has "--no-github: prints the manual next steps" "$OUT" "./scripts/setup-labels.sh && ./scripts/setup-milestones.sh"
hasnt "--no-github: no setup notice" "$OUT" "Git and GitHub setup"
t   "--no-github: base branch as before (main)" "$(jq -r .github.baseBranch "$tmp/p/zzalpha/.claude/kit.config.json")" "main"
# The same files as the unconfirmed run above, which is the scaffold init has always written.
norm() { ( cd "$1" && find . -type f ! -name kit.manifest.json | sort | while read -r f; do printf '%s %s\n' "$f" "$(sed -e "s#$2#NAME#g" "$f" | cksum)"; done ) }
t   "--no-github: the same file list as a run with no setup" "$(cd "$tmp/p/zzalpha" && find . -type f | sort)" "$(cd "$tmp/p/zzbravo" && find . -type f | sort)"
t   "--no-github: the same file contents (project name aside)" "$(norm "$tmp/p/zzalpha" zzalpha)" "$(norm "$tmp/p/zzbravo" zzbravo)"
run "$tmp" --target "$tmp/p/zzalpha" --profile minimal --no-github
t   "--no-github on an initialized project: refused as before (rc 1)" "$RC" "1"
has "--no-github on an initialized project: the same message" "$OUT" "already initialized"

# ── 12. a plan that refuses branch protection is a skip, not a failure ──────────────────────────
: > "$GHS/plan-refuses"; : > "$GHS/writes.log"
run "$tmp" "$tmp/p/free" --profile minimal --yes
t   "protection refused by the plan: rc 0" "$RC" "0"
has "protection refused by the plan: skipped, with the reason" "$OUT" "[skipped] protect develop"
has "protection refused by the plan: names HTTP 403" "$OUT" "HTTP 403"
hasnt "protection refused by the plan: no protect write" "$(cat "$GHS/writes.log")" "protect "
rm -f "$GHS/plan-refuses"

# ── 13. a failed step does not hide the ones after it ───────────────────────────────────────────
: > "$GHS/fail-labels"; : > "$GHS/writes.log"
run "$tmp" "$tmp/p/partial" --profile minimal --yes
t   "failed step: rc 1" "$RC" "1"
has "failed step: labels reported failed" "$OUT" "[failed ] labels"
has "failed step: a later step still ran" "$(cat "$GHS/writes.log")" "protect tester/partial develop"
has "failed step: the result names the failure again" "$OUT" "1 failed"
rm -f "$GHS/fail-labels"
run "$tmp/p/partial" --yes
t   "failed step, re-run: rc 0" "$RC" "0"
has "failed step, re-run: only the missing labels are created" "$OUT" "[done   ] labels"
hasnt "failed step, re-run: the repository is not created twice" "$(grep -c 'repo create tester/partial' "$GHS/writes.log")" "2"

: > "$GHS/fail-create"
run "$tmp" "$tmp/p/nocreate" --profile minimal --yes
t   "repository cannot be created: rc 1" "$RC" "1"
has "repository cannot be created: later steps are reported, not hidden" "$OUT" "[skipped] labels — needs the GitHub repository"
rm -f "$GHS/fail-create"

# ── 14. refusals before anything is written ─────────────────────────────────────────────────────
printf '{"new_project":"maybe"}\n' > "$tmp/a-bad.json"
run "$tmp" "$tmp/p/bad" --answers "$tmp/a-bad.json" --yes
t   "an answer that is not an option: rc 2" "$RC" "2"
has "an answer that is not an option: lists the options" "$OUT" "Choose one of: yes no"
run "$tmp" "$tmp/p/bad" --profile minimal --recipe nope --no-github
t   "unknown recipe: rc 2" "$RC" "2"
run "$tmp" --target "$tmp/p/loose" --recipe demo --force --no-github
t   "recipe on a folder with files: rc 2" "$RC" "2"
run "$tmp" "$tmp/p/Bad_Name" --profile minimal --recipe demo --no-github
t   "recipe with a folder name it cannot use: rc 2" "$RC" "2"
run "$tmp" "$tmp/p/bad" --answers "$tmp/nope.json"
t   "answers file missing: rc 2" "$RC" "2"
yes_if "refusals: nothing was created" '[ ! -e "$tmp/p/bad" ] && [ ! -e "$tmp/p/Bad_Name" ]'

# ── 15. the advisor: every question has exactly one recommended answer ──────────────────────────
: > "$tmp/a-none.json"; echo '{}' > "$tmp/a-none.json"
run "$tmp" "$tmp/p/defaults" --answers "$tmp/a-none.json" --no-github
t   "empty answers file: rc 0" "$RC" "0"
has "empty answers file: the recommended answer is taken and said so" "$OUT" '(recommended; "recipe" is not in the answers file)'
yes_if "empty answers file: the recommended recipe and database ran" '[ -f "$tmp/p/defaults/app/page.tsx" ] && [ -f "$tmp/p/defaults/lib/supabase/client.ts" ]'
ask_out="$( { printf '\n' | KIT_INIT_TTY=1 INIT_ANSWERS="" init_ask k "Question?" "why" "a|A|first" "b|B|second|R" "c|C|third"; } 2>&1 >/dev/null )"
t   "terminal: Enter alone takes the recommended option" "$( { printf '\n' | KIT_INIT_TTY=1 INIT_ANSWERS="" init_ask k "Question?" "why" "a|A|first" "b|B|second|R" "c|C|third"; } 2>/dev/null)" "b"
t   "terminal: exactly one option is marked recommended" "$(printf '%s\n' "$ask_out" | grep -c '(Recommended)')" "1"
t   "terminal: a number picks that option" "$( { printf '3\n' | KIT_INIT_TTY=1 INIT_ANSWERS="" init_ask k "Q?" "" "a|A|x" "b|B|y|R" "c|C|z"; } 2>/dev/null)" "c"

[ "$fail" -eq 0 ] && echo "init-guided-test: PASS" || echo "init-guided-test: FAIL"
exit "$fail"
