---
name: concrete
description: Cut AI slop from prose — padding, hedges, unearned adjectives, unverifiable claims, closing summaries that repeat the body. Diagnoses first, asks only when the answer changes the result, then rewrites and says why each cut was made. Targets durable artifacts (commits, PR and issue bodies, rules, ADRs, knowledge docs) automatically; chat and product copy on request.
when_to_use: Automatically before writing any durable artifact — a commit message, a PR or issue body, a rule, an ADR, a knowledge doc. On request (`/concrete chat` or `/concrete copy`) for assistant replies and end-user product copy. Not for code (that is karpathy-guidelines) and not for design decisions about UI copy.
---

# concrete

Prose that reads well and says nothing is worse than prose that reads badly, because nobody
notices it is empty. This skill finds the empty parts, discovers what should be there instead, and
cuts what is left over.

## The contract

| Decision | |
| --- | --- |
| **Target** | `artifacts` (default) · `chat` · `copy` — one catalogue, three profiles |
| **Output** | diagnosis → rewrite → the reason for each cut |
| **Questions** | asked ONLY when the answer changes the result |
| **Activation** | automatic for durable artifacts; explicit for chat and copy |
| **Deletion** | only by NAMED offense, **never by length**, with an untouchable list |

Never delete to hit a word count. A text can be long and clean; length is a signal to look, not a
licence to cut. Cutting for length removes evidence first, because evidence is bulkier than prose.

## The offense catalogue

Cut only what matches a named offense. Name the offense in the diagnosis so the author can argue.

| # | Offense | Cue | Action |
| --- | --- | --- | --- |
| O1 | **Preamble** | a sentence announcing what you are about to say, instead of saying it | delete; start at the first claim |
| O2 | **Self-narration** | "I will now…", "Let me…", "Before I explain…" | delete; do the thing |
| O3 | **Restatement** | repeats the question or the previous paragraph before adding anything | delete the repeat, keep the addition |
| O4 | **Closing summary** | a final paragraph restating the body | delete; the body already said it |
| O5 | **Empty transition** | "That said", "It's worth noting", "In essence", "Importantly" | delete; the sentence stands alone |
| O6 | **Hedge stack** | two or more of arguably / essentially / somewhat / it seems / perhaps / relatively | keep at most one hedge, and only if the uncertainty is real → often triggers Q1 |
| O7 | **Unearned adjective** | robust, significant, dramatic, seamless, powerful — with no number behind it | replace with the datum, or delete the adjective |
| O8 | **Triad padding** | three adjectives or nouns where one carries the meaning ("clean, maintainable and scalable") | keep the one that is load-bearing |
| O9 | **The escalation frame** | "not just X, but Y" · "more than X — it's Y" | state Y; drop the frame |
| O10 | **Jargon shield** | internal jargon standing in for the thing: wiring, seam, chrome, surface, leverage | name the thing (the same list `effort_title_lint` bans in effort titles) |
| O11 | **Decorative punctuation** | an em-dash used for rhythm rather than a real aside; a colon that introduces nothing | delete |
| O12 | **Enumerated nothing** | "there are several considerations" followed by none that matter | delete, or list the ones that do |
| O13 | **Unverifiable claim** | a statement nobody could check: "this improves quality", "this is more secure" | → **Q1**. Never rewrite it into fluency |
| O14 | **Undecided decision** | options described as if a conclusion; no choice made | → **Q2**. Never paper it over with confident phrasing |

O13 and O14 are the two that matter most. The rest is tidying; these two are where fluent prose
hides that nobody verified anything or decided anything.

## Untouchable — never cut, in any target

- Command output, exit codes, counts, dates, SHAs, `file:line`, label and flag names.
- **The reason a claim was rejected** — a rebuttal without its evidence is just an opinion.
- The verification section of a commit or PR: what was run and what came back.
- Verbatim quotes of what a person said.
- Standard and clause citations (ISO/IEC clause numbers, ADR numbers, issue numbers).
- **Stated limits** — "this is bypassable with `--no-verify`", "this is not an attestation". A
  limit deleted for brevity becomes an overclaim.

If a cut would remove one of these, the text is not slop; it is dense. Leave it.

## The interview — two questions, asked only when they change the result

Mechanical offenses (O1–O12) are cut without asking. There is nothing to discover; the words are
simply surplus. Ask only for O13 and O14:

- **Q1 — did you verify this, or assume it?** For an unverifiable claim. The answer is either a
  command and its output (which replaces the claim) or an admission (which changes it to "assumed,
  not verified"). Both are better than the original sentence.
- **Q2 — which of these is the decision?** For prose that lists options as if it had concluded. The
  answer becomes one sentence; the options move to a "considered and rejected" line or leave.

Two mechanical tests that replace a question:

- **Delete test** — remove the sentence. If nothing downstream changes and nobody would ask for it
  back, it was slop.
- **Datum test** — for every adjective of degree, ask which number supports it. No number, no
  adjective.

Ask at most those two, and only where they apply. If the author is absent (an unattended run), do
not invent an answer: mark the sentence `[unverified]` in the rewrite and say so in the diagnosis.

## Targets

| Target | Activation | Offenses | Notes |
| --- | --- | --- | --- |
| `artifacts` | **automatic** | all O1–O14 | Commits, PR and issue bodies, rules, ADRs, knowledge docs. This is where slop is permanent |
| `chat` | `/concrete chat` | O1–O9, O12–O14 | Follows the project's communication-style rule. **Exempt:** inline term definitions and comprehension checks a teaching mode asks for — those look like padding and are not |
| `copy` | `/concrete copy` | O5, O7, O8, O9, O11 | End-user product copy. It may be in a language other than the marker lists above, so judge by the offense, not the phrase. Design decisions about copy stay with the project's design skill |

## Output shape

1. **Diagnosis** — one line per finding: `O<n> <offense> — <the quoted fragment>`.
2. **Questions** — only Q1/Q2, only if they apply.
3. **The rewrite.**
4. **Cuts** — one line per deletion with its offense number. A reader must be able to audit what
   left and why.

Keep the diagnosis shorter than the text it diagnoses. An anti-slop report that is longer than its
subject has become the thing it audits.

## Boundaries

- **Not for code.** Overcomplication, non-surgical edits and unnecessary abstraction are
  `karpathy-guidelines`.
- **Not a design skill.** What the UI should say belongs to the project's design routing.
- **Not a terminology authority.** Which word is correct (defect vs nonconformity, concession vs
  waiver) belongs to the project's vocabulary rule, if it has one.
- **No emojis**, in this skill's output or anywhere in the kit.
- It has no opinion about being right. If the author defends a fragment, the fragment stays; the
  diagnosis names offenses, it does not overrule people.

## Applied to itself

This file was written under its own rules: no preamble, no closing summary, no adjective without a
datum. The catalogue's first client is the assistant — commit messages that open with a
self-narrating line (O2) and close by restating their own body (O4) are the most common case.
