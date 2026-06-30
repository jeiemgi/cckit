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

WT_START_REPO="${WT_START_REPO:-${KIT_REPO:-}}"

# _wt_set_port <app-env-file> <port> <issue-num> — append a per-worktree dev PORT to an app's
# .env.local, but only where one exists (i.e. the app is locally runnable). Idempotent: an existing
# PORT= line wins. The app dev scripts read ${PORT:-300X} (sub B) so this assignment takes effect.
_wt_set_port() {
  local file="$1" port="$2" num="$3"
  [[ -f "$file" ]] || return 0
  grep -q '^PORT=' "$file" 2>/dev/null && return 0
  printf '\n# kit worktree #%s — per-worktree dev port (#773)\nPORT=%s\n' "$num" "$port" >> "$file"
  echo "[#$num] PORT=$port -> $file" >&2
}

# wt_assign_ports <worktree> <issue-num> <root> — assign a per-worktree dev PORT to each app whose
# env file is listed in `.worktree.devPorts` of <root>/.claude/kit.config.json. Each entry is
# {path, base}; the port = base + (issue % 40) * <count> so lanes stay disjoint within and across
# worktrees. Config-driven (no hardcoded app paths) so the kit stays portable: a project with no
# `.worktree.devPorts` (or no kit.config.json) is a silent no-op. bash 3.2.
wt_assign_ports() {
  local wt="$1" num="$2" root="$3" cfg ports n offset i path base
  cfg="$root/.claude/kit.config.json"
  # jq is a stated requirement of this file (see header) — don't pre-check `command -v jq` here: the
  # `command -v … || return` idiom mis-fires under zsh, and the jq read below already no-ops on a
  # missing config / missing jq. Guard only on the config file existing.
  [[ -f "$cfg" ]] || return 0
  ports="$(jq -c '.worktree.devPorts // []' "$cfg" 2>/dev/null)" || return 0
  [[ -n "$ports" && "$ports" != "[]" ]] || return 0
  n="$(jq 'length' <<<"$ports" 2>/dev/null)"; [[ "$n" =~ ^[0-9]+$ && "$n" -gt 0 ]] || return 0
  offset=$(( num % 40 )); i=0
  while [[ "$i" -lt "$n" ]]; do
    path="$(jq -r ".[$i].path // empty" <<<"$ports")"
    base="$(jq -r ".[$i].base // empty" <<<"$ports")"
    [[ -n "$path" && "$base" =~ ^[0-9]+$ ]] && _wt_set_port "$wt/$path" $(( base + offset * n )) "$num"
    i=$(( i + 1 ))
  done
}

# wt_bootstrap <root> <worktree> <issue-num> — make a fresh worktree runnable for local dev.
# A new worktree inherits no .gitignored local config and no node_modules, and parallel worktrees
# collide on the hardcoded dev port. This copies the local env, installs deps, and assigns a
# per-worktree dev port. Every step is best-effort + idempotent — never fail the start (#773).
wt_bootstrap() {
  local root="$1" wt="$2" num="$3" rel src dst offset
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
  if [[ "${KIT_WT_INSTALL:-1}" != "0" ]] && command -v pnpm >/dev/null 2>&1; then
    echo "[#$num] pnpm install (set KIT_WT_INSTALL=0 to skip)..." >&2
    ( cd "$wt" && pnpm install --prefer-offline >/dev/null 2>&1 ) \
      && echo "[#$num] deps installed" >&2 \
      || echo "[#$num] pnpm install failed — run 'pnpm install' in the worktree manually" >&2
  fi
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
