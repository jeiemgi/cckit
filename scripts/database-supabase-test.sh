#!/usr/bin/env bash
# shellcheck shell=bash
# database-supabase-test.sh — the setup test of the Supabase database option (#456).
#
# A database option is offered by `cckit init` only while this file exists (databases/supabase.json
# names it as its `test`). It proves that following the option produces a correct setup:
#   - the env file has the variable names the descriptor declares, with placeholders, not values;
#   - the client code the option adds reads exactly those names;
#   - the env file is ignored by git, and a value already in it is neither changed nor printed;
#   - applying it twice changes nothing the second time.
# Offline by default: `pnpm` is a stub that records the packages in package.json.
#
# The build half is networked and opt-in, so the default run stays offline:
#   INIT_E2E_NETWORK=1 bash scripts/database-supabase-test.sh
# runs the shipped recipe (create-next-app, shadcn) with the real pnpm in a scratch folder
# (INIT_E2E_DIR, default a temp dir), applies this option, installs the kit with --no-github, and
# requires `pnpm build` to pass with the placeholder env values.
# errors: strict — a test runner: rc 1 on any failed assertion
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
E2E="${INIT_E2E_NETWORK:-0}"; E2E_DIR="${INIT_E2E_DIR:-}"
# shellcheck source=/dev/null
. "$ROOT/scripts/lib/test-env.sh" && test_env_seal
fail=0
t()      { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
has()    { if printf '%s' "$2" | grep -qF -- "$3"; then echo "ok: $1"; else echo "FAIL: $1 -> '$3' not in: $2"; fail=1; fi; }
hasnt()  { if printf '%s' "$2" | grep -qF -- "$3"; then echo "FAIL: $1 -> '$3' found"; fail=1; else echo "ok: $1"; fi; }
yes_if() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1 -> not true: $2"; fail=1; fi; }

command -v jq >/dev/null 2>&1 || { echo "database-supabase-test: jq absent — skipping (dependency-light gate)"; exit 0; }

# shellcheck source=/dev/null
. "$ROOT/scripts/lib/init-guide.sh"
DB="$ROOT/databases/supabase.json"
ENV_FILE="$(jq -r .envFile "$DB")"
NAMES="$(jq -r '.env[].name' "$DB")"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
tmp="$(cd "$tmp" && pwd -P)"
real_path="$PATH"
mkdir -p "$tmp/stubs"
cat > "$tmp/stubs/pnpm" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = "add" ] || exit 1
shift
for p in "$@"; do jq --arg p "$p" '.dependencies[$p] = "0.0.0-stub"' package.json > package.json.tmp && mv package.json.tmp package.json; done
STUB
chmod +x "$tmp/stubs/pnpm"
export PATH="$tmp/stubs:$PATH"

t "the option is valid"   "$(database_validate "$DB" 2>&1; echo "rc=$?")" "rc=0"
t "the option is offered" "$(database_offered "$DB"; echo "rc=$?")" "rc=0"

# ── a Next.js project the option is applied to ──────────────────────────────────────────────────
p="$tmp/app"; mkdir -p "$p"
printf '{"name":"app","dependencies":{"next":"1.0.0"}}\n' > "$p/package.json"
t "stack is detected from package.json" "$(database_stack_for "$DB" "$p")" "nextjs"
t "a project without the framework has no stack" "$(mkdir -p "$tmp/other" && echo '{"dependencies":{}}' > "$tmp/other/package.json" && database_stack_for "$DB" "$tmp/other"; echo "rc=$?")" "rc=1"

out="$(database_apply "$DB" nextjs "$p" 2>&1)"
for n in $NAMES; do
  yes_if "env file names $n" 'grep -q "^$n=" "$p/$ENV_FILE"'
  ph="$(jq -r --arg n "$n" '.env[] | select(.name == $n) | .placeholder' "$DB")"
  t "$n holds the descriptor's placeholder" "$(sed -n "s/^$n=//p" "$p/$ENV_FILE")" "$ph"
  yes_if "the client code reads $n" 'grep -rq "process\.env\.$n" "$p/lib/supabase"'
done
t "the env file has no variable the descriptor does not declare" \
  "$(grep -E '^[A-Z_]+=' "$p/$ENV_FILE" | cut -d= -f1 | sort | tr '\n' ' ')" "$(printf '%s\n' "$NAMES" | sort | tr '\n' ' ')"
for f in $(jq -r '.stacks.nextjs.files[].to' "$DB"); do
  yes_if "the option adds $f" '[ -f "$p/$f" ]'
done
for pk in $(jq -r '.stacks.nextjs.packages[]' "$DB"); do
  yes_if "package $pk is a dependency" 'jq -e --arg p "$pk" ".dependencies | has(\$p)" "$p/package.json" >/dev/null'
done
yes_if "the env file is ignored" 'grep -qxF "$ENV_FILE" "$p/.gitignore"'
has "every step is reported" "$out" "[done   ] $ENV_FILE"

# ── idempotent, and a value the user typed is neither changed nor shown ─────────────────────────
first="$(echo "$NAMES" | head -1)"
sed "s#^$first=.*#$first=https://typed-by-the-user.example#" "$p/$ENV_FILE" > "$p/$ENV_FILE.tmp" && mv "$p/$ENV_FILE.tmp" "$p/$ENV_FILE"
before="$(cd "$p" && find . -type f -print0 | sort -z | xargs -0 cksum)"
out="$(database_apply "$DB" nextjs "$p" 2>&1)"
t "second apply changes no file" "$(cd "$p" && find . -type f -print0 | sort -z | xargs -0 cksum)" "$before"
hasnt "second apply reports nothing done" "$out" "[done"
hasnt "a value in the env file never reaches the output" "$out" "typed-by-the-user"
hasnt "the printed steps carry no value from the env file" "$(database_steps "$DB" "$p")" "typed-by-the-user"
t "the user's value is still there" "$(sed -n "s/^$first=//p" "$p/$ENV_FILE")" "https://typed-by-the-user.example"

# In a git repository, an ignore rule from the framework's own .gitignore is enough.
if command -v git >/dev/null 2>&1; then
  g="$tmp/gitapp"; mkdir -p "$g"; git -C "$g" init -q
  printf '{"name":"app","dependencies":{"next":"1.0.0"}}\n' > "$g/package.json"; printf '.env*\n' > "$g/.gitignore"
  out="$(database_apply "$DB" nextjs "$g" 2>&1)"
  has "an existing .env* rule is enough" "$out" "[skipped] .gitignore"
  t "git ignores the env file" "$(git -C "$g" check-ignore "$ENV_FILE")" "$ENV_FILE"
fi

# ── opt-in: the real thing, networked ───────────────────────────────────────────────────────────
if [ "$E2E" = "1" ]; then
  export PATH="$real_path"
  work="${E2E_DIR:-$tmp/e2e}"; mkdir -p "$work"; proj="$work/shop"
  [ ! -e "$proj" ] || { echo "FAIL: $proj already exists — remove it first"; exit 1; }
  echo "── networked: cckit init $proj --recipe nextjs-shadcn --database supabase --no-github"
  ( cd "$work" && KIT_INIT_PREFLIGHT=0 KIT_INIT_BROWSER=0 KIT_INIT_TTY=0 CLAUDE_PLUGIN_ROOT="$ROOT" \
      bash "$ROOT/scripts/init.sh" "$proj" --recipe nextjs-shadcn --database supabase --no-github )
  t "networked: init rc" "$?" "0"
  yes_if "networked: a Next.js app"        'jq -e ".dependencies | has(\"next\")" "$proj/package.json" >/dev/null'
  yes_if "networked: shadcn/ui configured" '[ -f "$proj/components.json" ] && [ -f "$proj/components/ui/button.tsx" ] && [ -f "$proj/components/ui/card.tsx" ]'
  yes_if "networked: Supabase client wired" '[ -f "$proj/lib/supabase/client.ts" ] && jq -e ".dependencies | has(\"@supabase/ssr\")" "$proj/package.json" >/dev/null'
  yes_if "networked: the kit is installed" '[ -f "$proj/.claude/kit.config.json" ]'
  yes_if "networked: no git repository (--no-github)" '[ ! -e "$proj/.git" ]'
  for n in $NAMES; do yes_if "networked: $ENV_FILE names $n" 'grep -q "^$n=" "$proj/$ENV_FILE"'; done
  echo "── networked: pnpm build (placeholder env values)"
  ( cd "$proj" && pnpm build )
  t "networked: pnpm build rc" "$?" "0"
else
  echo "skip: the networked build check (set INIT_E2E_NETWORK=1 to run it)"
fi

[ "$fail" -eq 0 ] && echo "database-supabase-test: PASS" || echo "database-supabase-test: FAIL"
exit "$fail"
