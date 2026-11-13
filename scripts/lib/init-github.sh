#!/usr/bin/env bash
# shellcheck shell=bash
# init-github.sh — the git + GitHub half of `cckit init` (#456): every step between "a folder with
# the kit files in it" and "a repository `cckit start` can work on".
#
# The steps, in order. Each one checks first and is SKIPPED when its result is already there, so a
# re-run on a set-up project changes nothing; each reports done / skipped / failed through
# init_step (init-guide.sh), and a failed step never stops the ones after it.
#
#    1. git repository      git init (branch main) when the folder is not one
#    2. first commit        only on a repository with no commit yet
#    3. GitHub repository   adopt `origin`, or link / create <owner>/<name> (private unless IG_VISIBILITY=public)
#    4. base branch         create it from the current commit and push it
#    5. default branch      set to the base branch — only on a repository this run created
#    6. labels              create the ones setup-labels.sh lists and the repository lacks
#    7. milestones          setup-milestones.sh (it creates only the missing ones)
#    8. head branches       "automatically delete head branches" on merge
#    9. branch protection   the base branch: pull request required, branch up to date, no
#                           force-push, no deletion. A plan that refuses it (HTTP 403 on a private
#                           repository of a free account) is a skip with the reason, not a failure
#   10. Projects v2 ids     only when the project has a board
#   11. doctor              the read-only report
#
# Steps 3-10 write to GitHub. init_setup_plan prints all of them BEFORE any runs, and the caller
# (init.sh) runs init_setup_run only after one confirmation: a yes on a terminal, or --yes.
#
# Inputs (set by the caller): IG_TARGET (project dir), IG_REPO (owner/name), IG_BASE (base branch),
# IG_VISIBILITY (private|public), IG_PROJECTS_V2 (true|false), IG_KIT_ROOT (the kit), IG_DOCTOR (1|0).
#   init_setup_plan     print the numbered plan (local reads only)
#   init_setup_run      run it; rc 0, failures are counted in INIT_FAILED
# Requires: git, gh, jq. bash 3.2 compatible.
# errors: best-effort — a failed step is reported and counted in INIT_FAILED; the run continues

IG_CREATED=0     # 1 when THIS run created the GitHub repository
IG_REPO_OK=0     # 1 once the project has a GitHub repository to write to

_gs_git() { git -C "$IG_TARGET" "$@"; }
_gs_last() { printf '%s' "$1" | grep -v '^[[:space:]]*$' | tail -1 | cut -c1-200; }
_gs_refused_by_plan() { grep -qiE 'HTTP 403|Upgrade to GitHub' <<<"$1"; }

# init_setup_plan -> what will be attempted, from local state alone (no network).
init_setup_plan() {
  local in_git=0 has_commit=0 origin="" n=0
  if _gs_git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    in_git=1
    _gs_git rev-parse --verify -q HEAD >/dev/null 2>&1 && has_commit=1
    origin="$(_gs_git remote get-url origin 2>/dev/null || true)"
  fi
  echo "  On this computer:"
  if [ "$in_git" -eq 0 ]; then n=$((n + 1)); echo "    $n. Start version control in $IG_TARGET (git init)"; fi
  if [ "$has_commit" -eq 0 ]; then n=$((n + 1)); echo "    $n. Save the first version (first commit)"; fi
  [ "$n" -eq 0 ] && echo "    (nothing — it is already a git repository with commits)"
  echo "  On GitHub ($IG_REPO):"
  n=$((n + 1))
  if [ -n "$origin" ]; then
    echo "    $n. Use the repository this folder is already connected to"
  else
    echo "    $n. Create the $(printf '%s' "$IG_VISIBILITY" | tr '[:lower:]' '[:upper:]') repository $IG_REPO (or connect to it when it exists)"
  fi
  n=$((n + 1)); echo "    $n. Create the branch '$IG_BASE' and push it; make it the default branch of a new repository"
  n=$((n + 1)); echo "    $n. Add the labels and milestones the workflow uses (only the missing ones)"
  n=$((n + 1)); echo "    $n. Turn on \"automatically delete head branches\" after a merge"
  n=$((n + 1)); echo "    $n. Protect '$IG_BASE': changes arrive by pull request, up to date, no force-push"
  if [ "${IG_PROJECTS_V2:-false}" = "true" ]; then n=$((n + 1)); echo "    $n. Read the Projects v2 board's field ids"; fi
  echo "  Then: the cckit doctor report."
  echo "  A step whose result is already there is skipped."
}

_gs_step_git_init() {
  if _gs_git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    init_step skipped "git repository" "already one"; return 0
  fi
  if _gs_git init -q 2>/dev/null && _gs_git symbolic-ref HEAD refs/heads/main 2>/dev/null; then
    init_step done "git repository" "git init, branch main"
  else
    init_step failed "git repository" "git init did not work in $IG_TARGET"
  fi
}

_gs_step_first_commit() {
  local e out
  _gs_git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { init_step skipped "first commit" "no git repository (see above)"; return 0; }
  if _gs_git rev-parse --verify -q HEAD >/dev/null 2>&1; then
    init_step skipped "first commit" "the repository already has commits"; return 0
  fi
  # An env file is never part of the first commit.
  for e in .env .env.local; do
    [ -f "$IG_TARGET/$e" ] || continue
    _gs_git check-ignore -q "$e" 2>/dev/null || printf '%s\n' "$e" >> "$IG_TARGET/.gitignore"
  done
  if [ -z "$(_gs_git config user.name 2>/dev/null || true)" ] || [ -z "$(_gs_git config user.email 2>/dev/null || true)" ]; then
    init_step failed "first commit" "git does not know who you are yet. Run: git config --global user.name \"Your Name\" and git config --global user.email \"you@example.com\", then run cckit init again"
    return 0
  fi
  if out="$(_gs_git add -A 2>&1 && _gs_git commit -q -m "chore: set up the project with cckit" 2>&1)"; then
    init_step done "first commit"
  else
    init_step failed "first commit" "$(_gs_last "$out")"
  fi
}

_gs_step_repo() {
  local origin out url
  # IG_REPO is the name init.sh resolved: `gh repo view` in the folder when it has a remote.
  _gs_git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { init_step skipped "GitHub repository" "no git repository (see above)"; return 0; }
  origin="$(_gs_git remote get-url origin 2>/dev/null || true)"
  if [ -n "$origin" ]; then
    IG_REPO_OK=1
    init_step skipped "GitHub repository" "already connected to $IG_REPO"; return 0
  fi
  case "$IG_REPO" in
    */*) ;;
    *) init_step failed "GitHub repository" "could not read your GitHub account. Run: gh auth login — then run cckit init again"; return 0 ;;
  esac
  if out="$(gh repo view "$IG_REPO" --json url,sshUrl -q '[.url, .sshUrl] | @tsv' 2>/dev/null)" && [ -n "$out" ]; then
    url="$(printf '%s' "$out" | cut -f1).git"
    [ "${IG_PROTO:-https}" = "ssh" ] && [ -n "$(printf '%s' "$out" | cut -f2)" ] && url="$(printf '%s' "$out" | cut -f2)"
    if _gs_git remote add origin "$url" 2>/dev/null; then
      IG_REPO_OK=1; init_step done "GitHub repository" "$IG_REPO exists — connected this folder to it"
    else
      init_step failed "GitHub repository" "could not connect this folder to $IG_REPO"
    fi
    return 0
  fi
  if out="$(gh repo create "$IG_REPO" "--$IG_VISIBILITY" --source "$IG_TARGET" --remote origin 2>&1)"; then
    IG_CREATED=1; IG_REPO_OK=1
    init_step done "GitHub repository" "created $IG_REPO ($IG_VISIBILITY)"
  else
    init_step failed "GitHub repository" "$(_gs_last "$out")"
  fi
}

_gs_remote_has() { _gs_git ls-remote --exit-code --heads origin "$1" >/dev/null 2>&1; }

_gs_step_base_branch() {
  local cur out
  [ "$IG_REPO_OK" -eq 1 ] || { init_step skipped "branch $IG_BASE" "needs the GitHub repository (see above)"; return 0; }
  if ! _gs_git rev-parse --verify -q HEAD >/dev/null 2>&1; then
    init_step skipped "branch $IG_BASE" "nothing to push yet — the repository has no commit"; return 0
  fi
  if _gs_remote_has "$IG_BASE"; then
    init_step skipped "branch $IG_BASE" "GitHub already has it"; return 0
  fi
  cur="$(_gs_git symbolic-ref --short -q HEAD 2>/dev/null || true)"
  # A repository with no branch at all gets the current one first (main, the release branch).
  if [ -n "$cur" ] && [ "$cur" != "$IG_BASE" ] && [ -z "$(_gs_git ls-remote --heads origin 2>/dev/null)" ]; then
    out="$(_gs_git push -q -u origin "$cur" 2>&1)" || { init_step failed "branch $IG_BASE" "could not push $cur: $(_gs_last "$out")"; return 0; }
  fi
  _gs_git show-ref --verify -q "refs/heads/$IG_BASE" || _gs_git branch "$IG_BASE" >/dev/null 2>&1 || true
  if out="$(_gs_git push -q -u origin "$IG_BASE" 2>&1)"; then
    # Same commit, so switching moves no file. Only on a repository this run created: an existing
    # project's checkout is never moved.
    [ "$IG_CREATED" -eq 1 ] && [ "$cur" != "$IG_BASE" ] && _gs_git checkout -q "$IG_BASE" >/dev/null 2>&1 || true
    init_step done "branch $IG_BASE" "created from ${cur:-the current commit} and pushed"
  else
    init_step failed "branch $IG_BASE" "$(_gs_last "$out")"
  fi
}

_gs_step_default_branch() {
  local def out
  [ "$IG_REPO_OK" -eq 1 ] || { init_step skipped "default branch" "needs the GitHub repository (see above)"; return 0; }
  def="$(gh repo view "$IG_REPO" --json defaultBranchRef -q '.defaultBranchRef.name' 2>/dev/null || true)"
  if [ "$def" = "$IG_BASE" ]; then init_step skipped "default branch" "already $IG_BASE"; return 0; fi
  if [ "$IG_CREATED" -ne 1 ]; then
    init_step skipped "default branch" "it is '${def:-unknown}'; an existing repository keeps its own (to change it: gh repo edit $IG_REPO --default-branch $IG_BASE)"
    return 0
  fi
  if out="$(gh repo edit "$IG_REPO" --default-branch "$IG_BASE" 2>&1)"; then
    init_step done "default branch" "$IG_BASE"
  else
    init_step failed "default branch" "$(_gs_last "$out")"
  fi
}

_gs_step_labels() {
  local want have name color desc made=0 bad=0 total=0 out
  [ "$IG_REPO_OK" -eq 1 ] || { init_step skipped "labels" "needs the GitHub repository (see above)"; return 0; }
  want="$( cd "$IG_TARGET" && KIT_LABELS_LIST=1 bash "$IG_KIT_ROOT/scripts/setup-labels.sh" 2>/dev/null )" || want=""
  [ -n "$want" ] || { init_step failed "labels" "could not read the label list from the project config"; return 0; }
  if ! have="$(gh label list --repo "$IG_REPO" --limit 1000 --json name -q '.[].name' 2>&1)"; then
    init_step failed "labels" "$(_gs_last "$have")"; return 0
  fi
  while IFS="$(printf '\t')" read -r name color desc; do
    [ -n "$name" ] || continue
    total=$((total + 1))
    grep -qxF "$name" <<<"$have" && continue
    if out="$(gh label create "$name" --repo "$IG_REPO" --color "$color" --description "$desc" 2>&1)"; then made=$((made + 1)); else bad=$((bad + 1)); fi
  done <<EOF
$want
EOF
  if [ "$bad" -gt 0 ]; then init_step failed "labels" "$bad of $total could not be created: $(_gs_last "$out")"
  elif [ "$made" -eq 0 ]; then init_step skipped "labels" "all $total are there"
  else init_step done "labels" "created $made, $((total - made)) were there"; fi
}

_gs_step_milestones() {
  local out made
  [ "$IG_REPO_OK" -eq 1 ] || { init_step skipped "milestones" "needs the GitHub repository (see above)"; return 0; }
  if out="$( cd "$IG_TARGET" && bash "$IG_KIT_ROOT/scripts/setup-milestones.sh" 2>&1 )"; then
    made="$(printf '%s\n' "$out" | grep -c '^  ✓ ' || true)"
    if [ "${made:-0}" -eq 0 ]; then init_step skipped "milestones" "all are there"; else init_step done "milestones" "created $made"; fi
  else
    init_step failed "milestones" "$(_gs_last "$out")"
  fi
}

_gs_step_delete_head_branches() {
  local cur out
  [ "$IG_REPO_OK" -eq 1 ] || { init_step skipped "delete head branches on merge" "needs the GitHub repository (see above)"; return 0; }
  if ! cur="$(gh api "repos/$IG_REPO" --jq '.delete_branch_on_merge' 2>&1)"; then
    init_step failed "delete head branches on merge" "$(_gs_last "$cur")"; return 0
  fi
  if [ "$cur" = "true" ]; then init_step skipped "delete head branches on merge" "already on"; return 0; fi
  if out="$(gh api -X PATCH "repos/$IG_REPO" -F delete_branch_on_merge=true 2>&1)"; then
    init_step done "delete head branches on merge"
  else
    init_step failed "delete head branches on merge" "$(_gs_last "$out")"
  fi
}

# The protection cckit's rules ask for (merge-safety.md convention 1): a pull request is required,
# the branch must be up to date with the base before it merges, history stays linear, and the base
# is never force-pushed or deleted. No status check is named: a new project has no CI job yet.
_GS_PROTECTION='{"required_status_checks":{"strict":true,"contexts":[]},"enforce_admins":false,"required_pull_request_reviews":{"required_approving_review_count":0},"restrictions":null,"required_linear_history":true,"allow_force_pushes":false,"allow_deletions":false}'
_GS_PLAN_REASON="GitHub does not offer branch protection for a private repository on this account's plan (HTTP 403). It is available on a public repository or a paid plan"

_gs_step_protection() {
  local out
  [ "$IG_REPO_OK" -eq 1 ] || { init_step skipped "protect $IG_BASE" "needs the GitHub repository (see above)"; return 0; }
  if out="$(gh api "repos/$IG_REPO/branches/$IG_BASE/protection" 2>&1)"; then
    init_step skipped "protect $IG_BASE" "already protected"; return 0
  fi
  if _gs_refused_by_plan "$out"; then init_step skipped "protect $IG_BASE" "$_GS_PLAN_REASON"; return 0; fi
  if out="$(printf '%s' "$_GS_PROTECTION" | gh api -X PUT "repos/$IG_REPO/branches/$IG_BASE/protection" --input - 2>&1)"; then
    init_step done "protect $IG_BASE" "pull request required, branch up to date, no force-push"
  elif _gs_refused_by_plan "$out"; then
    init_step skipped "protect $IG_BASE" "$_GS_PLAN_REASON"
  else
    init_step failed "protect $IG_BASE" "$(_gs_last "$out")"
  fi
}

_gs_step_project_ids() {
  local out
  [ "${IG_PROJECTS_V2:-false}" = "true" ] || return 0
  if [ -f "$IG_TARGET/scripts/.project-ids.env" ]; then init_step skipped "Projects v2 ids" "already captured"; return 0; fi
  if [ ! -f "$IG_TARGET/scripts/capture-project-ids.sh" ]; then init_step failed "Projects v2 ids" "scripts/capture-project-ids.sh is not in the project"; return 0; fi
  if out="$( cd "$IG_TARGET" && bash scripts/capture-project-ids.sh 2>&1 )"; then
    init_step done "Projects v2 ids"
  else
    init_step failed "Projects v2 ids" "$(_gs_last "$out")"
  fi
}

_gs_step_doctor() {
  if [ "${IG_DOCTOR:-1}" != "1" ] || [ ! -f "$IG_KIT_ROOT/scripts/kit-doctor.sh" ]; then
    init_step skipped "doctor report" "turned off for this run"; return 0
  fi
  echo ""
  if ( cd "$IG_TARGET" && bash "$IG_KIT_ROOT/scripts/kit-doctor.sh" --dry-run ); then
    init_step done "doctor report" "nothing to fix"
  else
    init_step failed "doctor report" "it lists things to fix above"
  fi
}

# init_setup_run -> every step, in order. rc 0 always; INIT_FAILED carries the failures.
init_setup_run() {
  export GH_PROMPT_DISABLED=1
  IG_PROTO="$(gh config get git_protocol 2>/dev/null || echo https)"
  echo ""
  echo "Project setup — $IG_TARGET"
  _gs_step_git_init
  _gs_step_first_commit
  _gs_step_repo
  _gs_step_base_branch
  _gs_step_default_branch
  _gs_step_labels
  _gs_step_milestones
  _gs_step_delete_head_branches
  _gs_step_protection
  _gs_step_project_ids
  _gs_step_doctor
  return 0
}
