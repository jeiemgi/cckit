# Plain language — say draft, review and approve

The person you work with here writes, plans or approves content and may never have used git. cckit
still runs the work on worktrees, branches and pull requests. This rule decides what you **say**;
it changes nothing you **run**.

It is installed because `plainLanguage.enabled` is `true` in `{{CONFIG_REL}}`. Set the key to
`false` and delete this file to turn it off.

## The words

| What cckit does | What you say |
| --- | --- |
| records a task (`cckit task new`) | "I added it to the task list." |
| creates a worktree and a branch (`cckit task start`, `cckit start`) | "I started the draft." |
| commits and pushes | "I saved the draft." |
| opens a pull request (`cckit task finish`, `cckit pr`) | "The draft is ready for review." Then the link. |
| a reviewer approves the pull request | "It is approved." |
| the pull request merges into `{{BASE_BRANCH}}` | "It is approved and part of the shared version." |
| the gate or a check fails | "A check failed." Then what failed, in one sentence. |
| two branches changed the same lines | "Two drafts changed the same passage." |
| an effort and its sub-issues | "the campaign and its pieces" |
| task states `todo` · `doing` · `review` · `done` | "not started" · "in progress" · "waiting for review" · "done" |

## Rules

1. **Say draft, review, approve.** Do not say worktree, branch, commit, push, rebase, diff, merge
   or pull request on your own.
2. **Name the mechanics when asked.** If the person uses one of those words, or asks how it works
   or where a file is, answer with the real names, paths and commands. Then return to plain words.
3. **Give the review link as a link.** The person opens it in a browser and approves there. Say
   what approving does: the piece becomes part of the shared version and its task is marked done.
4. **A failure stays a failure.** Report a failed step in plain words: what did not happen, what it
   means for the piece, what you will do next. Add the command and its error text on one line at the
   end, so someone technical can act on it. Never report a step as done because the plain wording
   has no word for the error.
5. **Ask in plain words too.** "Is this ready for review?" — not "Should I open the PR?"

## What this rule does not change

- **Commands.** You run the same `cckit` verbs with the same arguments.
- **Durable text.** Commit messages, pull request titles and bodies, and task files follow their
  own rules. A pull request title stays a Conventional Commit subject.
- **Text a program reads.** Output handed to another agent or a tool, and machine lines such as
  `Closes #N`, are written as those readers expect.

## Precedence

`communication-style.md` sets format and length. This rule sets vocabulary. Where a rule tells you
to report a branch name, a worktree path or a pull request number in a summary, give the plain
sentence first and the identifier after it, so the person can pass it to someone technical.
