# Merge safety — current base, coupled chains, the gate on the integration branch

Three conventions about what a branch must pass before it lands. Each was a correction the kit's
maintainer repeated across projects before it was written down; they were recorded as cckit effort
`E231` on 2026-09-07.

Complements `branch-naming.md` § *Merge order* (which PR lands first), `task-management.md` § *Rules*
(one PR per issue, and its coupled-chain exception) and `effort-model.md` (subs merge into one
integration branch). A profile may install only some of those; the precedence stated under each
convention applies to whichever are present.

## 1. `MERGEABLE` is not safe — bring the branch onto the current base first

**Before a PR merges, its branch contains the tip of `develop` and the gate has passed on
that tree.** `MERGEABLE` is not that evidence.

- **Origin:** a PR cut from a base that had since moved was merged because GitHub reported it
  mergeable. It reverted a sibling PR that had landed in between: 7,285 lines removed, with no
  conflict and no failing check to announce it.
- **What `MERGEABLE` says:** git can combine the branch and the base without a textual conflict.
  It does not say the PR's diff leaves a sibling's lines alone, and it does not say the combined
  tree passes the gate — a check run reports the tree it ran on, and the base has moved since.
- **Behind?** `git fetch origin develop`, then
  `git rev-list --count HEAD..origin/develop`. Anything but `0` means the branch is stale.

The steps, from the branch's own worktree:

```bash
git fetch origin develop
git rebase origin/develop                 # or: git merge origin/develop
git diff --stat origin/develop...HEAD     # read the deletions
# run the project's gate here
git push --force-with-lease                       # a plain push after a merge
```

- **Read the deletions.** A file or a block the issue never asked to remove, showing as deleted in
  that diff, is the revert. Stop and restore it before pushing.
- **Merge instead of rebase** when other branches are cut from this one (an effort branch with live
  sub-branches): a rebase rewrites the commits they sit on.
- **After every landing, the remaining open PRs are stale again.** Repeat for the next one in
  `branch-naming.md`'s merge order; do not merge a batch that was current only before the first of
  them landed.

**What the kit's merge ops do today.** Neither makes a stale, conflict-free branch current — that
is why this is a rule for whoever merges, not a description of the tooling.

| Op | What it merges | What it rebases |
| --- | --- | --- |
| `cckit watch --merge` (the captain) | a PR it classifies `CLEAN`: `mergeable` is `MERGEABLE`, `mergeStateStatus` is `CLEAN`, `UNSTABLE`, `HAS_HOOKS` or empty, no check is failing or pending, no review verdict is failing, and no policy floor trips | nothing. `BEHIND` is classified `BLOCKED` and skipped — not merged, not rebased |
| `cckit merge` / `/kit-task-pr-merge` | the PR as GitHub has it | only a PR GitHub reports `CONFLICTING`, and only when run from the PR's own head branch: `git rebase origin/<base>`, then `git push --force-with-lease`. A branch that is behind but conflict-free is merged as it stands |

GitHub reports `BEHIND` only when the base branch's protection requires branches to be up to date
before merging. With that setting off, a stale branch reads `CLEAN` and the captain merges it. Turn
the setting on for `develop` and the captain's `BLOCKED` becomes the enforcement of this
convention.

**Precedence — `branch-naming.md` § *Merge order*.** That section decides the order; this rule
decides what each PR passes before its turn. They do not conflict on order. Its lockfile rule
(*merge one, then rebase the others*) is this convention applied to lockfiles; this rule extends it
to every PR, so where that section is silent about rebasing a non-lockfile PR, this rule wins.

## 2. A coupled chain ships as ONE PR

**Changes that only work together land as one PR — and ideally one issue — not one PR per step.**
A chain is coupled when any step merged alone leaves `develop` broken, or when each step
edits what the step before it wrote: a sequenced migration set, a rename plus its call sites, a
schema change plus the code that reads it.

- **Origin:** the incident class of convention 1. The PRs of a chain are siblings cut from the
  same base, and each one is stale the moment the one before it lands. A single PR has no siblings
  to revert.
- **Split only when** a step is independent of the others, or needs its own review gate — a data
  backfill, an access-policy change.
- **Inside the PR, keep one commit per step.** The review still reads step by step; the merge is
  atomic.

**Precedence — `task-management.md` § *Rules*** (*One PR per issue — no monster PRs*, with its
exception for a coupled migration/DDL chain) **and `branch-naming.md`** (*One PR per issue. No
monster PRs*, *Smaller before larger*). `task-management.md` states the exception for migrations;
this rule is the general form and wins on scope — any coupled chain qualifies, not only DDL. Its
split criteria are the same ones listed above and stand. Against the size guidance, this rule wins
for a coupled chain: a large diff is not a reason to split steps that cannot land apart. For
independent changes, one PR per issue still holds.

## 3. Re-run the gate on the integration branch after the subs merge

**After the last sub-branch merges into the integration branch, the gate runs on the integration
branch itself, before its PR opens.** A green gate on every sub is not a green gate on the merge
of them.

- **Origin:** a correction the maintainer repeated — the gate had been run on each sub and not
  again on the integration branch once the subs were merged into it.
- **Why per-sub green is not enough:** each sub's gate ran on that sub's tree. Two subs can each
  pass and still break together — one renames a helper the other calls, both add the same key to
  a config file — and no sub's gate saw the combination.
- **Where it applies:** an effort's `effort/<N>` branch after its `sub/<N><letter>` branches merge
  in (`effort-model.md`), and any other branch that collects several branches before one PR.
  Sequential subs committed straight onto the integration branch are covered once the gate has
  run on its final commit.
- **No kit verb runs it for you.** `cckit effort pr` opens the PR and `cckit effort close` merges
  it; neither runs the project's gate. Run it by hand, then open the PR. The PR's CI is the
  second run, not a substitute for the first: it reports after the PR is already up for review.
- **Then convention 1 applies to the integration branch** like any other: it is brought onto the
  current `develop` and the gate passes there before it merges.

**Precedence — `effort-model.md` § *Lifecycle*.** Its table lists `orchestrate → effort-pr →
effort-close` with no gate step between them. This rule adds that step and wins where the table is
read as "merge the subs, open the PR".
