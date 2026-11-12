# Code retrieval — ask the graph before you search the tree

> Active because this project ran `cckit add graft` (`codeGraph.provider` is `graft` in the project
> config). Graft is third-party software by NanoNets / Trail (MIT); cckit is not affiliated with
> either and vendors none of its code. To remove: `graft uninstall -y --no-global`, delete this
> file, and set `codeGraph.provider` to `"none"`.

Where a code graph exists, query it. Where one does not, search with Grep/Glob as before. This rule
says which.

## The routing table

Use these when the three conditions under *Fallback* all hold:

| What you need | Verb | Instead of |
| --- | --- | --- |
| Where is X handled? | `graft ask "<task>"` | grepping a guessed term, opening files, following imports |
| Every occurrence of a pattern | `graft grep "<regex>"` | a plain regex search — same hits, grouped by enclosing symbol |
| The API of one file | `graft skeleton <file>` | reading the whole file for its signatures |
| What breaks if I change X? | `graft callers <symbol> -d 2` | grepping the symbol name and judging the hits |
| What does this symbol call? | `graft callers <symbol> --direction out` | reading the body and chasing each call |
| Orient in an unfamiliar repo | `graft map` | listing directories and opening entry points |
| What does my diff reach? | `graft blast --base origin/<base>` | judgement |

`-d N` is the depth of the walk; `-d all` is the full blast radius.

These verbs parse with tree-sitter: no model and no API key, so they cost nothing to run.
`graft build --deep` is the one command that calls an LLM, under the user's own key. Nothing in
this rule runs it; do not run it unless the user asks.

## Fallback — a hard rule

**Fall back to Grep/Glob silently when any one of these is false. Never block work, ask the user,
or report an error because the graph is missing.**

1. `graft --version` exits 0 (the binary is installed and loads).
2. The repo has a `graft/` directory (the graph was built — `graft init` or `graft build`).
3. The file or language you are asking about is one Graft indexes.

On 3: a file whose extension is not in Graft's list is skipped, not indexed. **There is no shell
grammar**, nor one for Markdown, YAML, SQL or CSS — on those files every verb above returns
nothing, and an empty answer from the graph means "not indexed", not "does not exist". Confirm
with Grep before concluding that something is absent.

The same precedent as a linter that is skipped when it is not installed: the graph is an
accelerator, and its absence changes no exit code and fails no step.

## When not to query the graph at all

- **You already know the path.** Read it. A graph query to confirm a path you hold is a wasted turn.
- **Non-code retrieval** — the doc, rule, or ADR that answers a question. Graft does not index prose.
- **Text that is not a symbol** — a log message, a config value, a string literal in an unindexed
  file. Grep is the right tool.

## What is and is not claimed

Graft's README reports fewer tool calls (46%), fewer tokens (42%) and 54% → 66% on SWE-bench
Verified. Those are the vendor's own harness numbers. **cckit has not reproduced them** and this
rule does not assert them. Route through the graph because `callers`, `blast` and symbol-grouped
`grep` answer questions a text search cannot, not because of a benchmark this project did not run.

Graft makes two kinds of network call of its own, per its README: a daily npm version check and one
batched anonymous usage ping. `graft telemetry disable` or `DO_NOT_TRACK=1` turns the ping off.
