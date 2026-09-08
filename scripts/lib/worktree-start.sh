#!/usr/bin/env bash
# worktree-start.sh — the canonical "start a worktree for an issue" git-mechanic.
#
# Family 1 of kit-engine-boundary.md (rule #1/#2): one bash home for the op, consumed by the
# kit-task-start skill, scripts/orchestrate.sh, and `kit task start`. No second implementation.
#
#   wt_start <issue-number> [slug-override]
#     stdout: "<worktree-path>|<branch>|<issue-number>"   (one line, machine-readable)
#     stderr: human progress
#     returns: 0 on success (created or reused), 1 on failure
#
# Requires: gh, jq, git, scripts/lib/gh-project.sh (board update). bash 3.2 compatible.
# errors: strict — rc 1 on failure; a half-made worktree is never reported as ready

WT_START_REPO="${WT_START_REPO:-${KIT_REPO:-}}"

# _wt_set_port <app-env-file> <port> <issue-num> — append a per-worktree dev PORT to an app's
# .env.local, but only where one exists (i.e. the app is locally runnable). Idempotent: an existing
# PORT= line wins.
#
# BEST-EFFORT, NOT A GUARANTEE. This write only takes effect for an app that actually reads the
# file. A script like `next dev -p ${PORT:-3003}` is expanded by the npm-script shell, which never
# reads .env.local, so the value is INERT for it and every worktree falls back to the same default.
# cckit therefore does not RELY on it: everything cckit launches itself passes the port explicitly
# (scripts/lib/qa-lane.sh injects one QA_PORT_<service> per service). Treat the .env.local write as
# a convenience for apps that do read it — and if you start a dev server by hand in a worktree,
# check which port you actually got.
_wt_set_port() {
  local file="$1" port="$2" num="$3"
  [[ -f "$file" ]] || return 0
  grep -q '^PORT=' "$file" 2>/dev/null && return 0
  printf '\n# kit worktree #%s — per-worktree dev port (#773)\nPORT=%s\n' "$num" "$port" >> "$file"
  echo "[#$num] PORT=$port -> $file" >&2
}

# wt_assign_ports <worktree> <issue-num> <root> — assign a per-worktree dev PORT to each app whose
# env file is listed in `.worktree.devPorts` of <root>/.claude/kit.config.json. Each entry is
# {path, base}; the port = base + (issue % 40) * <stride> so lanes stay disjoint within and across
# worktrees (stride = `worktree.devPortStride`, default 10 — never the service count, see below). Config-driven (no hardcoded app paths) so the kit stays portable: a project with no
# `.worktree.devPorts` (or no kit.config.json) is a silent no-op. bash 3.2.
# ── port SLOTS: an allocation, not a hash (the QA lane depends on lanes never colliding) ──────
# `issue % 40` is a hash: two issues 40 apart get byte-identical ports, and a repo whose numbers are
# in the thousands hits that constantly (#1700 and #1740 in the same wave is unremarkable). A slot is
# RECORDED instead, so uniqueness is by construction rather than by hoping about issue numbers.
#
# State lives beside the event log under the git-common-dir, so it is worktree-durable and shared by
# every checkout. Each line: <issue>\t<slot>\t<worktree-path>. A slot whose worktree is gone is
# reclaimed on the next call, which is what keeps the 40 slots from leaking away over a long project.
_wt_slots_file() {
  local gcd
  gcd="$(git -C "${1:-.}" rev-parse --git-common-dir 2>/dev/null)" || return 1
  case "$gcd" in /*) : ;; *) gcd="$(cd "${1:-.}" && cd "$gcd" 2>/dev/null && pwd)" || return 1 ;; esac
  printf '%s/kit-portslots.tsv' "$gcd"
}

# _wt_slot_for <root> <issue-num> <worktree> — echo this issue's slot (0-39), allocating on first
# call. IDEMPOTENT: an issue keeps its slot for as long as its worktree exists, so re-running
# `cckit start` never renumbers a live lane. Falls back to the old hash (with a warning) only when
# every slot is genuinely held.
_wt_slot_for() {
  local root="$1" num="$2" wt="$3" f line i held mine
  f="$(_wt_slots_file "$root")" || { printf '%s' $(( num % 40 )); return 0; }
  [[ -f "$f" ]] || : > "$f" 2>/dev/null || { printf '%s' $(( num % 40 )); return 0; }

  # Reclaim: keep only rows whose worktree still exists (or that have no path recorded).
  local tmp; tmp="$(mktemp 2>/dev/null)" || tmp=""
  if [[ -n "$tmp" ]]; then
    while IFS="$(printf '\t')" read -r i_num i_slot i_path; do
      [[ -n "$i_num" ]] || continue
      if [[ -z "$i_path" || -d "$i_path" ]]; then printf '%s\t%s\t%s\n' "$i_num" "$i_slot" "$i_path" >> "$tmp"; fi
    done < "$f"
    mv "$tmp" "$f" 2>/dev/null || rm -f "$tmp"
  fi

  # Already allocated? Keep it.
  mine="$(awk -F"\t" -v n="$num" '$1==n {print $2; exit}' "$f" 2>/dev/null)"
  if [[ "$mine" =~ ^[0-9]+$ ]]; then printf '%s' "$mine"; return 0; fi

  held="$(cut -f2 "$f" 2>/dev/null | tr '\n' ' ')"
  i=0
  while [[ "$i" -lt 40 ]]; do
    case " $held " in *" $i "*) : ;; *) printf '%s\t%s\t%s\n' "$num" "$i" "$wt" >> "$f" 2>/dev/null; printf '%s' "$i"; return 0 ;; esac
    i=$(( i + 1 ))
  done
  echo "[#$num] warn: all 40 dev-port slots are held — falling back to a hashed port (collisions possible); run cckit gc" >&2
  printf '%s' $(( num % 40 ))
}

wt_assign_ports() {
  # `apppath`, not `path`: under zsh `path` is tied to PATH (special array); a bare `path` local
  # would clobber the command search path on assignment. A namespaced name is inert.
  local wt="$1" num="$2" root="$3" cfg ports n offset i apppath base stride spread
  # Both supported layouts (self-host root cckit.config.json · scaffolded
  # .claude/kit.config.json) via the same resolver used below. Hardcoding the scaffolded
  # path made this a silent no-op in every self-hosting repo: ports read as "assigned"
  # and nothing was ever written.
  cfg="$(_wt_cfg "$root")" || return 0
  # jq is a stated requirement of this file (see header) — don't pre-check `command -v jq` here: the
  # `command -v … || return` idiom mis-fires under zsh, and the jq read below already no-ops on a
  # missing config / missing jq. Guard only on the config file existing.
  [[ -f "$cfg" ]] || return 0
  ports="$(jq -c '.worktree.devPorts // []' "$cfg" 2>/dev/null)" || return 0
  [[ -n "$ports" && "$ports" != "[]" ]] || return 0
  n="$(jq 'length' <<<"$ports" 2>/dev/null)"; [[ "$n" =~ ^[0-9]+$ && "$n" -gt 0 ]] || return 0

  # STRIDE — the distance between one worktree's port block and the next. It must NOT be the
  # service count: with stride == n, two bases that are congruent mod n hand the same port to two
  # different worktrees. Real example (bases 3001/3003/3004, n=3): worktree offset k+1's admin port
  # (3004+3k) IS worktree offset k's api port. Configurable as `worktree.devPortStride`; the default
  # leaves room for up to 10 services per project.
  stride="$(jq -r '.worktree.devPortStride // empty' "$cfg" 2>/dev/null)"
  [[ "$stride" =~ ^[0-9]+$ && "$stride" -gt 0 ]] || stride=10

  # The invariant that keeps blocks disjoint: every base must sit inside ONE stride-wide window.
  # Warn rather than fail — the ports still work, they just stop being collision-proof, and a
  # config the owner can fix should not break `cckit start`.
  spread="$(jq -r '[.[].base] | (max - min)' <<<"$ports" 2>/dev/null)"
  if [[ "$spread" =~ ^[0-9]+$ && "$spread" -ge "$stride" ]]; then
    echo "[#$num] warn: worktree.devPorts bases span $spread >= stride $stride — port blocks can overlap across worktrees; widen worktree.devPortStride" >&2
  fi

  offset="$(_wt_slot_for "$root" "$num" "$wt")"
  [[ "$offset" =~ ^[0-9]+$ ]] || offset=$(( num % 40 ))
  i=0
  while [[ "$i" -lt "$n" ]]; do
    apppath="$(jq -r ".[$i].path // empty" <<<"$ports")"
    base="$(jq -r ".[$i].base // empty" <<<"$ports")"
    [[ -n "$apppath" && "$base" =~ ^[0-9]+$ ]] && _wt_set_port "$wt/$apppath" $(( base + offset * stride )) "$num"
    i=$(( i + 1 ))
  done
}

# ── Where does `pnpm install` actually have work to do? (#255) ────────────────────────────────
# The bootstrap install used to run unconditionally at the worktree ROOT. In a repo whose root
# manifest declares no dependencies (a published CLI, a docs-only repo, a shell toolkit), pnpm has
# nothing to resolve — but it still WRITES a 9-line `pnpm-lock.yaml` with an empty `.: {}` importer.
# That stray lockfile then trips the captain's own policy floor (captain.sh, lockfile/dependency-
# graph paths) and HOLDS the PR for human review. The helpers below answer "is there anything to
# install, and where?" from the project's ACTUAL manifest — never from a hardcoded layout.

# _wt_cfg <dir> — path to <dir>'s project config, or nothing. Mirrors config-path.sh's two supported
# layouts (self-host root `cckit.config.json`, scaffolded `.claude/kit.config.json`) without taking
# a source-time dependency on it — worktree-start.sh is sourced standalone by effort-ops.sh.
_wt_cfg() {
  [[ -f "$1/cckit.config.json" ]]       && { printf '%s\n' "$1/cckit.config.json"; return 0; }
  [[ -f "$1/.claude/kit.config.json" ]] && { printf '%s\n' "$1/.claude/kit.config.json"; return 0; }
  return 1
}

# _wt_json_has <file> <jq-filter> <fallback-regex> — true when <file> satisfies <jq-filter>. jq is
# the stated dependency of this lib, but the install decision must stay correct without it, so a
# whitespace-stripped regex over the raw JSON is the fallback. Never fails the caller.
_wt_json_has() {
  local file="$1" filter="$2" re="$3"
  [[ -f "$file" ]] || return 1
  if command -v jq >/dev/null 2>&1; then
    jq -e "$filter" "$file" >/dev/null 2>&1
  else
    tr -d ' \n\t' < "$file" 2>/dev/null | grep -qE "$re"
  fi
}

# _wt_manifest_has_deps <dir> — true when <dir>/package.json declares at least ONE dependency in any
# of the four dependency blocks. An empty block (`"dependencies": {}`) counts as none: pnpm would
# resolve nothing and write only the empty-importer lockfile.
_wt_manifest_has_deps() {
  _wt_json_has "$1/package.json" \
    '[(.dependencies,.devDependencies,.optionalDependencies,.peerDependencies)
      | select(type=="object") | length] | add // 0 | . > 0' \
    '"(dependencies|devDependencies|optionalDependencies|peerDependencies)":\{"'
}

# _wt_yaml_has_members <file> — true when a pnpm-workspace.yaml declares at least one ACTUAL member
# pattern under `packages:`. The KEY alone is not enough: `packages: []` and a `packages:` with an
# empty block below it declare no members, so pnpm resolves nothing and writes only the empty-
# importer lockfile — the exact #255 symptom. Handles both YAML sequence forms:
#   packages: ["apps/*"]     (inline flow)        packages:            (block)
#                                                   - "apps/*"
# Comments are stripped first so `packages: []  # later` and `- # nothing` can't fake a member.
_wt_yaml_has_members() {
  [[ -f "$1" ]] || return 1
  awk '
    { line = $0; sub(/^[[:space:]]*#.*$/, "", line); sub(/[[:space:]]+#.*$/, "", line) }
    inblock {
      if (line ~ /^[[:space:]]*$/) next
      # a member entry: "- " followed by something real
      if (line ~ /^[[:space:]]*-[[:space:]]*[^[:space:]]/) { found = 1; exit }
      inblock = 0   # any other content ends the block without a member
    }
    !inblock {
      if (line ~ /^[[:space:]]*packages:[[:space:]]*\[/) {
        rest = line; sub(/^[^[]*\[/, "", rest); gsub(/[[:space:]]/, "", rest)
        if (rest !~ /^\]/) { found = 1; exit }   # non-empty inline flow sequence
      } else if (line ~ /^[[:space:]]*packages:[[:space:]]*$/) {
        inblock = 1
      }
    }
    END { exit(found ? 0 : 1) }
  ' "$1" 2>/dev/null
}

# _wt_is_workspace_root <dir> — true when <dir> is the root of a package-manager workspace WITH AT
# LEAST ONE MEMBER. Such a root legitimately declares no dependencies of its own (the members hold
# them) and its root lockfile is the real one, so `pnpm install` there IS genuine work.
#
# A declaration with no members is NOT a workspace root, and this distinction is the whole point:
# `packages: []`, `"workspaces": []`, `"workspaces": {}` and `"workspaces": {"packages": []}` all
# leave pnpm with nothing to resolve, so treating them as workspace roots would re-create #255.
# Likewise a `pnpm-workspace.yaml` carrying only settings (pnpm 10 `overrides:` /
# `onlyBuiltDependencies:`) with no `packages:` key at all.
_wt_is_workspace_root() {
  local d="$1" f
  for f in "$d/pnpm-workspace.yaml" "$d/pnpm-workspace.yml"; do
    _wt_yaml_has_members "$f" && return 0
  done
  # package.json `workspaces`: the array form IS the member list; the object form (npm/yarn) keeps
  # it under `.packages` alongside `nohoist`. Either way, count real non-empty patterns.
  _wt_json_has "$d/package.json" \
    'def members: if type=="array" then . elif type=="object" then (.packages // []) else [] end;
     ((.workspaces // null) | members | map(select(type=="string" and length > 0)) | length) > 0' \
    '"workspaces":(\["|\{[^}]*"packages":\[")'
}

# _wt_safe_target <worktree> <target> — echo the normalized, worktree-relative form of <target> when
# it is SAFE to install in; nothing + rc 1 otherwise. A target MUST stay inside the worktree.
#
# This is not hypothetical: a worktree lives at `<root>/.claude/worktrees/<kind>+<N>-<slug>`, three
# levels under the primary checkout, so an installPaths entry of `../../..` would run `pnpm install`
# in the SHARED main checkout — writing node_modules and a pnpm-lock.yaml into whatever another
# session has parked there. Config is project-controlled input, so it gets validated like input.
#
# Two gates, because they catch different escapes:
#   • lexical — reject an absolute path, and resolve `.`/`..` segments, failing if they climb above
#     the worktree. Pure parameter expansion (no `set --`, which zsh does not word-split), so it
#     works on a path that does not exist yet and behaves identically in bash and zsh.
#   • physical — when the directory does exist, compare `pwd -P` against the worktree's, which is
#     the only thing that catches a symlink pointing out of the tree.
_wt_safe_target() {
  local wt="$1" t="$2" rest seg out="" base abs
  [[ -n "$t" ]] || return 1
  case "$t" in /*) return 1 ;; esac   # absolute — never a worktree-relative target
  rest="$t"
  while [[ -n "$rest" ]]; do
    seg="${rest%%/*}"
    if [[ "$seg" == "$rest" ]]; then rest=""; else rest="${rest#*/}"; fi
    case "$seg" in
      ''|'.') continue ;;
      '..')
        [[ -n "$out" ]] || return 1                       # climbing above the worktree root
        case "$out" in */*) out="${out%/*}" ;; *) out="" ;; esac ;;
      *) out="${out:+$out/}$seg" ;;
    esac
  done
  out="${out:-.}"
  base="$(cd -P "$wt" 2>/dev/null && pwd -P)" || return 1
  if [[ -d "$wt/$out" ]]; then
    abs="$(cd -P "$wt/$out" 2>/dev/null && pwd -P)" || return 1
    case "$abs" in "$base"|"$base"/*) : ;; *) return 1 ;; esac
  fi
  printf '%s\n' "$out"
}

# wt_install_targets <worktree> — emit one worktree-relative directory per line that the bootstrap
# should run `pnpm install` in. Every emitted target is validated to live INSIDE the worktree
# (_wt_safe_target). Empty output means "nothing to install" — the correct answer for a
# dependency-free root. Decision order:
#   1. `.worktree.installPaths` in the project config wins outright — explicit project intent for
#      repos whose Node projects live in subdirectories (e.g. ["docs-site"]). `[]` means install
#      nothing. This is the generic escape hatch; the kit hardcodes no project's layout.
#   2. Otherwise the worktree root ".", but ONLY when its manifest declares dependencies or it is a
#      workspace root.
#   3. Otherwise nothing.
wt_install_targets() {
  local wt="$1" cfg paths n i p safe
  if cfg="$(_wt_cfg "$wt")" && command -v jq >/dev/null 2>&1; then
    paths="$(jq -c '.worktree.installPaths // empty' "$cfg" 2>/dev/null)"
    if [[ -n "$paths" && "$paths" != "null" ]]; then
      n="$(jq 'length' <<<"$paths" 2>/dev/null)"; [[ "$n" =~ ^[0-9]+$ ]] || return 0
      i=0
      while [[ "$i" -lt "$n" ]]; do
        p="$(jq -r ".[$i] // empty" <<<"$paths")"
        if [[ -n "$p" ]]; then
          if safe="$(_wt_safe_target "$wt" "$p")"; then
            printf '%s\n' "$safe"
          else
            echo "wt_install_targets: refusing installPaths entry '$p' — outside the worktree" >&2
          fi
        fi
        i=$(( i + 1 ))
      done
      return 0
    fi
  fi
  _wt_manifest_has_deps "$wt" || _wt_is_workspace_root "$wt" || return 0
  printf '.\n'
}

# wt_bootstrap <root> <worktree> <issue-num> — make a fresh worktree runnable for local dev.
# A new worktree inherits no .gitignored local config and no node_modules, and parallel worktrees
# collide on the hardcoded dev port. This copies the local env, assigns a per-worktree dev port, and
# installs deps WHERE THERE ARE ANY (wt_install_targets — #255). Every step is best-effort +
# idempotent — never fail the start (#773).
wt_bootstrap() {
  local root="$1" wt="$2" num="$3" rel src dst offset target where ran
  [[ -d "$wt" ]] || return 0

  # 1. Copy gitignored local config the worktree can't inherit: every .env.local* + project ids.
  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    src="$root/$rel"; dst="$wt/$rel"
    [[ -f "$src" ]] || continue
    [[ -f "$dst" ]] && continue   # idempotent: never clobber edits already made in the worktree
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst" && echo "[#$num] copied $rel" >&2
  done < <(cd "$root" && {
    find . -name '.env.local*' \
      -not -path './node_modules/*' -not -path './.git/*' -not -path './.claude/worktrees/*' 2>/dev/null
    [[ -f scripts/.project-ids.env ]] && echo './scripts/.project-ids.env'
  } | sed 's|^\./||' | sort -u)

  # 2. Assign a per-worktree dev PORT per app (base + offset*lanes from the issue number) so two
  #    worktrees never fight for the same port. The app→base map is config-driven
  #    (`.worktree.devPorts` in kit.config.json) so the kit carries no hardcoded app paths.
  wt_assign_ports "$wt" "$num" "$root"

  # 3. Install deps — node_modules is per-worktree, not shared. Opt out with KIT_WT_INSTALL=0.
  #    Runs ONLY where wt_install_targets says there is genuinely something to install. A root
  #    manifest with no dependencies is skipped: pnpm would resolve nothing and leave behind an
  #    empty `pnpm-lock.yaml` that the captain's lockfile policy floor then holds the PR on (#255).
  if [[ "${KIT_WT_INSTALL:-1}" != "0" ]] && command -v pnpm >/dev/null 2>&1; then
    ran=0
    while IFS= read -r target; do
      [[ -n "$target" ]] || continue
      # Re-validate containment at the point of USE, not just where the target was produced: this
      # is the line that actually `cd`s and runs pnpm, so it is the one that must never be talked
      # into stepping outside the worktree (a `../../..` would land in the shared main checkout).
      target="$(_wt_safe_target "$wt" "$target")" || continue
      [[ -d "$wt/$target" && -f "$wt/$target/package.json" ]] || continue
      ran=1
      [[ "$target" == "." ]] && where="" || where=" in $target"
      echo "[#$num] pnpm install$where (set KIT_WT_INSTALL=0 to skip)..." >&2
      ( cd "$wt/$target" && pnpm install --prefer-offline >/dev/null 2>&1 ) \
        && echo "[#$num] deps installed$where" >&2 \
        || echo "[#$num] pnpm install$where failed — run 'pnpm install' there manually" >&2
    done < <(wt_install_targets "$wt")
    [[ "$ran" == "0" ]] \
      && echo "[#$num] no dependencies declared — skipping pnpm install" >&2
  fi
  return 0
}

# ── Idle-worktree pool (OPT-IN, KIT_WT_POOL=1) ──────────────────────────────────────────────
# Treehouse-style reuse: instead of always creating a fresh worktree, recycle an IDLE one whose
# work already landed — saving the `git worktree add` + env copy + dependency install. OFF by
# default: with KIT_WT_POOL unset/0, wt_start takes the exact same create path as before and none
# of these helpers run. A worktree is REUSABLE only when ALL of these hold (conservative — if
# unsure, don't reuse; fall through to create):
#   • it lives under .claude/worktrees/ (a pooled tree — never the main checkout or the target)
#   • it is not locked
#   • its branch is already merged into origin/${KIT_BASE_BRANCH:-main} (the committed work landed — recycling it
#     destroys nothing; the old branch ref survives in the object store regardless)
#   • its working tree is clean (no staged/unstaged/untracked changes — recover-before-prune)
#   • no LIVE session owns it (kit-sessions registry: no live pid sitting in that dir)

# _wt_mtime <path> — file mtime as epoch seconds (BSD stat, then GNU stat). Picks the oldest tree.
_wt_mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null; }

# _wt_list <root> — emit one "<path>\t<branch-or-->\t<locked:0|1>" line per worktree (porcelain).
_wt_list() {
  local root="$1" line wt_path="" branch="" locked="0"
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) wt_path="${line#worktree }" ;;
      "branch refs/heads/"*) branch="${line#branch refs/heads/}" ;;
      "detached") branch="-" ;;
      "locked"*) locked="1" ;;
      "") [[ -n "$wt_path" ]] && printf '%s\t%s\t%s\n' "$wt_path" "${branch:--}" "$locked"
          wt_path=""; branch=""; locked="0" ;;
    esac
  done < <(git -C "$root" worktree list --porcelain 2>/dev/null)
  [[ -n "$wt_path" ]] && printf '%s\t%s\t%s\n' "$wt_path" "${branch:--}" "$locked"
}

# _wt_branch_merged <root> <branch> — true when <branch> is an ancestor of origin/${KIT_BASE_BRANCH:-main} (landed).
_wt_branch_merged() {
  local root="$1" branch="$2"
  [[ -n "$branch" && "$branch" != "-" ]] || return 1
  git -C "$root" merge-base --is-ancestor "refs/heads/$branch" origin/${KIT_BASE_BRANCH:-main} 2>/dev/null
}

# _wt_is_clean <path> — true only when the worktree exists AND has no staged/unstaged/untracked
# changes. A missing/zombie dir (git -C fails) is reported NOT clean, so it can never be recycled.
_wt_is_clean() {
  local out
  out="$(git -C "$1" status --porcelain 2>/dev/null)" || return 1
  [[ -z "$out" ]]
}

# _wt_session_owns <root> <path> — true when a LIVE Claude session sits in <path> (or a subdir),
# per the kit-sessions registry (.git/kit-sessions/*.json, written by session-registry.sh). A dead
# pid is not an owner. No registry → no known live owner (returns false).
_wt_session_owns() {
  local root="$1" wt_path="$2" common reg f opid ocwd
  common="$(git -C "$root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  reg="$common/kit-sessions"
  [[ -d "$reg" ]] || return 1
  for f in "$reg"/*.json; do
    [[ -e "$f" ]] || continue
    case "$f" in "$reg"/cache-*) continue ;; esac
    opid="$(jq -r '.pid // 0' "$f" 2>/dev/null)"
    [[ "$opid" =~ ^[1-9][0-9]*$ ]] || continue
    kill -0 "$opid" 2>/dev/null || continue
    ocwd="$(jq -r '.cwd // empty' "$f" 2>/dev/null)"
    case "$ocwd" in "$wt_path"|"$wt_path"/*) return 0 ;; esac
  done
  return 1
}

# _wt_pool_find <root> <target> — path of the OLDEST reusable pooled worktree, or nothing. Applies
# the full eligibility gate above; <target> (the path wt_start is about to use) is always excluded.
_wt_pool_find() {
  local root="$1" target="$2" wtdir best="" best_mt="" wt_path branch locked mt
  wtdir="$root/.claude/worktrees/"
  while IFS=$'\t' read -r wt_path branch locked; do
    [[ -n "$wt_path" ]] || continue
    case "$wt_path" in "$wtdir"*) : ;; *) continue ;; esac
    [[ "$wt_path" == "$target" ]] && continue
    [[ -d "$wt_path" ]] || continue
    [[ "$locked" == "1" ]] && continue
    _wt_branch_merged "$root" "$branch" || continue
    _wt_is_clean "$wt_path" || continue
    _wt_session_owns "$root" "$wt_path" && continue
    mt="$(_wt_mtime "$wt_path")"; [[ "$mt" =~ ^[0-9]+$ ]] || mt=0
    if [[ -z "$best" || "$mt" -lt "$best_mt" ]]; then best="$wt_path"; best_mt="$mt"; fi
  done < <(_wt_list "$root")
  [[ -n "$best" ]] && printf '%s\n' "$best"
}

# wt_pool_status — diagnostic listing of pooled worktrees + their reuse signals (read-only; never
# mutates). Shows branch / merged-into-develop? / clean? / live-session? / overall reusable?.
wt_pool_status() {
  local root wtdir wt_path branch locked merged clean owned reusable any=0
  root="$(git worktree list --porcelain | awk '/^worktree /{print $2; exit}')"
  [[ -n "$root" ]] || { echo "wt_pool_status: not in a git repo" >&2; return 1; }
  wtdir="$root/.claude/worktrees/"
  git -C "$root" fetch origin "${KIT_BASE_BRANCH:-main}" --quiet 2>/dev/null || true
  printf '%-44s %-26s %-7s %-6s %-8s %s\n' "WORKTREE" "BRANCH" "MERGED" "CLEAN" "SESSION" "REUSABLE"
  while IFS=$'\t' read -r wt_path branch locked; do
    [[ -n "$wt_path" ]] || continue
    case "$wt_path" in "$wtdir"*) : ;; *) continue ;; esac
    any=1
    _wt_branch_merged "$root" "$branch" && merged="yes" || merged="no"
    _wt_is_clean "$wt_path" && clean="yes" || clean="no"
    _wt_session_owns "$root" "$wt_path" && owned="live" || owned="-"
    if [[ "$locked" != "1" && "$merged" == "yes" && "$clean" == "yes" && "$owned" == "-" ]]; then
      reusable="yes"
    else
      reusable="no"
    fi
    printf '%-44s %-26s %-7s %-6s %-8s %s\n' "${wt_path#"$wtdir"}" "$branch" "$merged" "$clean" "$owned" "$reusable"
  done < <(_wt_list "$root")
  [[ "$any" == "1" ]] || echo "(no pooled worktrees under $wtdir)"
}

wt_start() {
  local num="${1:-}" slug_override="${2:-}" root meta title kind slug branch wt reused cand
  [[ -n "$num" ]] || { echo "wt_start: issue number required" >&2; return 1; }

  root="$(git worktree list --porcelain | awk '/^worktree /{print $2; exit}')"
  [[ -n "$root" ]] || { echo "wt_start: not in a git repo" >&2; return 1; }

  # The board's Status is set server-side by built-in automations (Item closed→Done, PR
  # merged→Done) — wt_start no longer writes In Progress, so no board helpers are loaded here.

  meta="$(gh issue view "$num" --repo "$WT_START_REPO" --json title,labels 2>/dev/null)" \
    || { echo "[#$num] issue not found" >&2; return 1; }
  title="$(echo "$meta" | jq -r '.title')"
  kind="$(echo "$meta" | jq -r '([.labels[].name | select(startswith("kind:"))][0] // "kind:task") | sub("^kind:";"")')"
  if [[ -n "$slug_override" ]]; then
    slug="$slug_override"
  else
    slug="$(echo "$title" \
      | sed -E 's/^\[[^]]+\][[:space:]]*//' \
      | tr '[:upper:]' '[:lower:]' \
      | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g' \
      | cut -c1-40)"
  fi
  branch="$kind/$num-$slug"
  wt="$root/.claude/worktrees/${kind}+${num}-${slug}"

  git -C "$root" fetch origin "${KIT_BASE_BRANCH:-main}" --quiet
  if git -C "$root" worktree list --porcelain | grep -q "/${kind}+${num}-${slug}$"; then
    echo "[#$num] reusing worktree $wt" >&2
  else
    reused=""
    # OPT-IN (KIT_WT_POOL=1): recycle an idle, already-landed worktree instead of creating one.
    # Safe by construction: _wt_pool_find only returns a clean, merged, session-free tree, and we
    # only attempt it when the new branch does not yet exist — so re-pointing can't collide with a
    # branch checked out elsewhere. Any hiccup leaves `reused` empty and falls through to the
    # unchanged create path below; with the flag off this whole block is skipped.
    if [[ "${KIT_WT_POOL:-0}" == "1" ]] && ! git -C "$root" show-ref --verify --quiet "refs/heads/$branch"; then
      cand="$(_wt_pool_find "$root" "$wt")"
      if [[ -n "$cand" ]] && git -C "$root" worktree move "$cand" "$wt" >/dev/null 2>&1; then
        # The recycled tree is now at the conventional path with its env + dependencies intact
        # (they moved with the dir — the pool's whole payoff). Re-point it to a fresh branch off
        # the latest develop; the clean+merged+branch-absent preconditions make -B reliable.
        git -C "$wt" checkout -B "$branch" origin/${KIT_BASE_BRANCH:-main} >/dev/null 2>&1 || true
        reused="1"
        echo "[#$num] reused idle worktree $wt" >&2
      fi
    fi
    if [[ -z "$reused" ]]; then
      git -C "$root" worktree add -B "$branch" "$wt" origin/${KIT_BASE_BRANCH:-main} >/dev/null 2>&1 \
        || { echo "[#$num] worktree add failed (branch $branch may exist elsewhere)" >&2; return 1; }
      echo "[#$num] created worktree $wt (branch $branch)" >&2
    fi
  fi

  # Bootstrap the worktree for local dev: copy local env, install deps, assign a dev port (#773).
  # Best-effort — a bootstrap hiccup never fails the start.
  wt_bootstrap "$root" "$wt" "$num" || true

  # Register with zoxide so `kit cd <issue|slug>` can jump here (no-op when zoxide is absent).
  command -v zoxide >/dev/null && zoxide add "$wt" >/dev/null 2>&1 || true

  # Mark the issue In Progress on the board. The board's built-in automations own the other
  # transitions server-side (Item added→Todo, PR linked→In Review, closed/merged→Done) — but GitHub
  # has no "branch started" trigger, so the kit owns In Progress. Cheap now: an O(1) issue.projectItems
  # lookup on the org board, not a full-board scan. Best-effort — a board hiccup never fails the start.
  if source "$root/scripts/lib/gh-project.sh" 2>/dev/null; then
    [[ -n "${STATUS_FIELD_ID:-}" ]] || load_project_ids >/dev/null 2>&1 || true
    # Claim precheck (#124): if the issue is ALREADY In Progress on the board, another session may
    # already own it — warn (never block; the start still proceeds) so two agents don't collide.
    if command -v project_issue_status >/dev/null 2>&1; then
      local _prev_status; _prev_status="$(project_issue_status "$num" 2>/dev/null || true)"
      [[ "$_prev_status" == "In Progress" ]] \
        && echo "[#$num] ⚠ already In Progress on the board — another session may own this issue; continuing." >&2
    fi
    item="$(project_find_item_by_issue "$num" 2>/dev/null)"
    if [[ -z "$item" ]]; then
      local content_id
      content_id="$(gh api graphql -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){issue(number:$n){id}}}' \
        -F o="${WT_START_REPO%/*}" -F r="${WT_START_REPO#*/}" -F n="$num" --jq '.data.repository.issue.id' 2>/dev/null)"
      [[ -n "$content_id" ]] && item="$(project_add_item "$content_id" 2>/dev/null)"
    fi
    [[ -n "$item" && -n "${STATUS_FIELD_ID:-}" && -n "${STATUS_OPT_IN_PROGRESS:-}" ]] \
      && project_set_single_select "$item" "$STATUS_FIELD_ID" "$STATUS_OPT_IN_PROGRESS" >/dev/null 2>&1 \
      && echo "[#$num] board → In Progress" >&2 || true
  fi

  echo "$wt|$branch|$num"
}
