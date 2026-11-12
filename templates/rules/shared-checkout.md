# Shared checkout — the primary checkout belongs to every session at once

Three conventions about the one directory every session on a machine has in common: the primary
checkout of the repository. Each was a correction the kit's maintainer repeated across projects
before it was written down; they were recorded as cckit effort `E231` on 2026-09-07.

Complements `branch-naming.md` § *Parallel work — one worktree per agent* (two agents never share a
directory) and § *Branch lifecycle* (never work on the base branch), and `delegation-brief.md`
§ *Standing gotchas* (refresh a worktree's base; commit through a literal path). A profile may
install only some of those; the precedence stated under each convention applies to whichever are
present.

**The primary checkout** is the directory the repository was cloned into — the first entry of
`git worktree list`. Every worktree under `.claude/worktrees/` hangs off it and shares its refs,
its stash stack and its `.cckit/` state. To tell which one you are in:

```bash
git worktree list --porcelain | head -1                  # the primary checkout's path
[ "$(git rev-parse --git-dir)" = "$(git rev-parse --git-common-dir)" ] && echo "primary checkout"
```

## 1. Never move the primary checkout by hand

**In the primary checkout, do not run a git command that moves `HEAD`, the index or the working
tree: `checkout`, `switch`, `pull`, `merge`, `rebase`, `reset`, `stash`.** It stays parked on
`{{BASE_BRANCH}}` with a clean tree, and no session treats it as its own.

- **Origin:** an incident, observed 2026-07-03. Several sessions were live on one repository; the
  primary checkout was found parked on a feature branch, then on the base branch, without the
  session reading it having moved it. Git has no lock for this: one session's `checkout` replaces
  the files under every other session that is reading or editing them.
- **Read without moving.** `git fetch origin {{BASE_BRANCH}}` writes remote-tracking refs only and
  is safe from any directory. Read the base as `origin/{{BASE_BRANCH}}`
  (`git log origin/{{BASE_BRANCH}}`, `git show origin/{{BASE_BRANCH}}:<file>`), never by pulling the
  primary checkout to look at it.
- **Check before assuming.** `git -C <primary checkout> status -sb` prints the branch it is parked
  on. Do not assume it is `{{BASE_BRANCH}}`, and do not "fix" it when it is not: another session
  may be mid-task there. Report it.
- **The stash stack is shared too.** `refs/stash` lives in the common git directory, so a bare
  `git stash pop` in any worktree can pop an entry another session pushed. Set work aside with a
  WIP commit on your own branch.

**How this squares with the close ops.** The kit's merge and close ops do check out and pull the
base in the primary checkout — `cckit merge` (`scripts/lib/kit-task-ops.sh:424-425`:
`git checkout <base>` then `git pull --ff-only origin <base>`) and `cckit effort close`
(`scripts/lib/effort-ops.sh:1025-1026`: `git checkout <base>` then `git pull origin <base>`). They
are the one sanctioned mover, and this rule is what makes them safe: with the primary checkout
already on `{{BASE_BRANCH}}` and clean, the checkout switches nothing and the pull is a
fast-forward. Both lines end in `|| true`, so when a session has left the primary checkout dirty or
on another branch the op carries on and the checkout stays stale, silently. The rule therefore
binds git typed by hand or by an agent; it does not ask you to avoid the verbs.

**Precedence — `branch-naming.md` § *Branch lifecycle*.** That section says a merge "switches to
the base branch and pulls". It describes the close op, which stands. This rule wins for every other
command: a hand-run `git checkout {{BASE_BRANCH}} && git pull` in the primary checkout is the thing
it forbids.

**Precedence — `delegation-brief.md` § *Standing gotchas*.** Its "refresh the base first"
(`git fetch` then `git reset --hard origin/<base>`) is an instruction for a fresh branch in an
isolation worktree. This rule wins on where: that reset is never run in the primary checkout.

## 2. Work in a worktree, always

**Every change — a one-line fix included — is made in a worktree created for it.**
`cckit start <issue>` and `cckit effort start <N>` create one from a fresh `{{BASE_BRANCH}}`; an
agent's isolation worktree counts.

- **Origin:** the same incident. The close ops only ever check out the base, so a primary checkout
  parked on a feature branch means a session checked that branch out there instead of in a
  worktree.
- **What already enforces part of this:** the base-branch commit guard blocks a `git commit` while
  `HEAD` is on the base, and `cckit orchestrate` leases each branch to one writer. Neither stops a
  session from checking out a feature branch in the primary checkout and working there, which is
  the case this convention covers.
- **Run git against a literal path.** `git -C <worktree path>` or `cd <worktree path> && git …`,
  with the path written out. A path held in a shell variable can resolve to the primary checkout.

**Precedence — `branch-naming.md` § *Parallel work*.** That section's "one agent = one git
worktree" is about two agents colliding. This rule extends it to a single session: one agent alone
still does not work in the primary checkout, because it cannot know it is alone.

## 3. Call a freshly merged verb from a current worktree

**When a command on your `PATH` resolves into the primary checkout, it is as old as the branch that
checkout is parked on.** After a merge, run the new behaviour from a worktree cut from the current
base — `<worktree>/bin/<tool>` — not from `PATH`.

- **Origin:** two incidents on 2026-07-03, both with the CLI symlinked from `PATH` into the primary
  checkout. A verb merged minutes earlier answered "unknown command", because the checkout was
  parked on a branch that predated it. And the version check reported the project as "ahead of
  plugin 0.3.0", reading the version file of that same stale branch.
- **When it applies:** a symlinked source install, where `PATH` points into a repository that is
  also being developed. Check with `readlink "$(command -v <tool>)"`. An install that lives
  elsewhere — a package manager, a separate clone — is not moved by anyone's branch, and this
  convention does not apply to it.
- **What to do instead of pulling.** Do not bring the primary checkout current to get the verb
  (convention 1). Create or reuse a worktree on the current base and call its copy. The primary
  checkout catches up at the next close op.
- **Scaffolded files behave the same way.** A session started in the primary checkout loads the
  rules, skills and hooks of the branch it is parked on. A change to them that merged since is
  read by a session started in a current worktree.

**Precedence.** No shipped rule says which copy of a tool to run; this one stands alone. Where
`delegation-brief.md` is installed, its project-specific section is the place to record the tool
and the path for your project.
