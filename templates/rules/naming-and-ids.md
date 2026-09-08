# Naming & IDs

Canonical tokens for efforts, sub-issues, chains, tasks and PRs, so a reference always says
**what kind of thing it points at**.

## The problem this solves

GitHub issues and pull requests share **one number sequence**. `#241` is an effort, `#242` a
sub-issue, `#248` a PR — and nothing in `#N` distinguishes them. No convention can fix that
*inside* `#N`. The fix is to stop writing efforts and PRs as bare `#N`.

A second problem: a sub-issue's own number is invisible where you look for it.
`[Effort 257] 8 · Gate releases` tells you effort 257, step 8 — but acting on it needs `#265`,
which appears nowhere in that title. You should be able to act on what you can already see.

## The tokens

| Thing | Token | Written as |
| --- | --- | --- |
| **Effort** | `E<n>` | `[E241] steady progress order and cadence` |
| **Sub-issue** (a step in an effort) | `E<n>.<step>` | `[E241.2] effort chain verb sets the order` |
| **Standalone task** (no parent effort) | `#<n>` | `#209 task pr-merge cleanup removes the wrong worktree` |
| **Pull request** | `PR <n>` | `PR 268 merged` |

`<n>` is the effort's **own GitHub issue number**. `<step>` is its 1-based position in the
effort, the same index the sub title already carries.

Two absolutes:

- An effort is **never** written bare as `#241`. Write `E241`.
- A PR is **never** written bare as `#268`. Write `PR 268`.

Everything else stays `#N`, which now unambiguously means *a standalone issue*.

## Why `E241.2` and not the sub's own number

`E241.2` is derivable from what you are already looking at. The sub's title says effort 241,
step 2 — so you can act on it without first resolving `#243`. That is the whole point: the
identifier you read is the identifier you type.

```shell
cckit start E241.2      # not: cckit start 243
```

Both resolve to the same worktree. The number still works; `E241.2` is what you can remember.

## PR titles

A PR title carries its token in trailing **square brackets**, after the conventional-commit
subject:

```text
feat(effort): chain verb sets the order [E241.2]
fix(start): don't plant an empty root pnpm-lock.yaml [#255]
chore(security): update docs-site deps to clear Dependabot alerts [#249]
```

- Effort and sub PRs carry `[E<n>]` or `[E<n>.<step>]`.
- Standalone task PRs carry `[#<n>]`.
- The conventional-commit prefix is unchanged and still governs release-please's version bump.
  The token is additive; it never replaces `type(scope):`.

### What is enforced today vs. what this rule targets

**Enforced now:** `effort_pr_title_check` (`scripts/lib/effort.sh`) requires a `[#<num>]` token —
the exact `[#num]` when given a number, otherwise any `[#digits]` — and `effort_pr` refuses to open
a PR without it. That check runs on **effort PRs only**; standalone task PRs are unchecked.

**This rule targets** `[E<n>]` / `[E<n>.<step>]` on effort and sub PRs, and the check extended to
every PR. Until that ships, `[#<num>]` is correct and `effort_pr` will keep generating it.

Do not hand-write `[E241.2]` into a PR title before the checker understands it — `effort_pr` would
reject the title for lacking `[#241]`. The migration is tracked in the implementation issue for
this rule, and it must move the generator (`effort_pr_title`), the validator
(`effort_pr_title_check`) and this section together.

**Brackets, never parentheses — this is load-bearing.** GitHub's squash-merge appends the PR
number in parentheses when it writes the commit subject, so the trailing-parens slot is already
taken:

```text
feat(core): agents can see what cckit provides [#220] (#230)
                                               ↑ the work   ↑ the PR
```

A token in parentheses would produce `… (E241.2) (#275)` — two parentheticals with no way to tell
which is which, recreating the ambiguity this rule exists to remove. Shape carries the meaning:
**square brackets are the work, parentheses are the PR.** The repo already writes titles this way;
this rule makes it binding rather than incidental.

**Every PR title carries a token.** A title with no token is a PR you cannot trace back to the
work that asked for it.

## Branches keep their existing form — deliberately

Branches stay `<kind>/<issue-number>-<slug>` (see `rules/branch-naming.md`). The `E` token does
**not** go into a branch name.

This is a safety constraint, not a style preference. `wt_issue_number` derives a branch's issue
number by requiring a pure-lowercase `kind`, a `/`, and pure digits before the first `-`. Even with
a valid kind prefix, a branch named `feat/e241.2-chain-verb` parses to **no issue number** — the
segment before the first `-` is `e241.2`, not digits — and a branch with no issue number gets
**no `gc` issue-open protection** — `cckit gc` would classify a live branch as SAFE to delete.
That regression has happened before in this repo; see the comment block in
`scripts/lib/worktree-issue.sh` explaining why sub-branch parsing exists at all.

The token belongs where humans read. Branch names are where tooling parses safety.

## Chains

A chain is a linear dependency between steps of one effort, written with `→`:

```text
E241.1 → E241.2 → E241.3
```

Chains are always within a single effort. A dependency **across** efforts is written with full
tokens (`E241.3 → E257.1`) and is a dependency, not a chain.

## In prose

Write the token, then the name on first mention if the reader needs it:

> `E241.2` (the chain verb) is up next, and `PR 268` already landed the priority sort.

Do not decorate a token with a second identifier. `E241.2 (#243)` is noise — pick one, and in
human-facing text the token is the one that carries meaning.

## Labels

Labels are the board's axes. A label earns its place only if it **varies** and something
**reads** it — a constant label is noise on every issue, and a write-only label is metadata
nobody consumes.

| Prefix | Values | Read by | Purpose |
| --- | --- | --- | --- |
| `priority:` | `p0` `p1` `p2` `p3` | `pm_prio_sort` (wave ordering) | urgency within a wave |
| `ctx:` | `S` `M` `L` `XL` | `_ep_weight` (session budget) | how much of a session it costs |
| `flow:` | `core` `docs` … | effort dispatch | which flow owns it |
| `role:` | `tech-lead` `docs` … | delegation brief | who it is written for |
| `kind:` | must discriminate | board grouping | what sort of work it is |
| `slug:` | one per effort | `effort_slug_resolve` | resolve a name to an effort |

### Rules

- **A label must vary.** `kind:task` on every issue in the repo's history tells you nothing.
  Either give `kind:` real values or drop it.
- **A label must be read.** If nothing consumes it, delete the label *and* the code that writes
  it. `par:seq|wide|<n>` was written by `effort_new` and read by nothing.
- **Every value in a scale needs a label.** `_ep_weight` scores `XL=8` and falls back to `2` for
  anything unknown, so an `XL` effort with no `ctx:XL` label silently weighs the same as an `M`.
  A scale the code knows but the board cannot express is a scale that quietly misreports.
- **Do not create per-item labels beyond `slug:`.** They grow without bound and match one issue
  each, which makes them useless as a board axis.
- **Leave `autorelease:*` alone** — release-please owns those.

### Priority means urgency, not membership

`priority:` only orders work if its values are actually distributed. A default that lands on
almost everything turns the wave sort into a no-op, since sorting a column of identical values
changes nothing. Set the priority that is true, and re-triage when the distribution drifts.

## Quick reference

| You see | It is |
| --- | --- |
| `E241` | an effort |
| `E241.2` | step 2 of effort 241 |
| `#209` | a standalone issue |
| `PR 268` | a pull request |
| `… [E241.2] (#275)` | a squashed commit: the work, then the PR that carried it |
