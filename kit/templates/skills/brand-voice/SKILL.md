---
name: brand-voice
description: >
  Record the brand's voice, key messages and banned phrasings in `brand/voice.md`, and check a
  draft against it. The file is what `copywriting` and `campaign` read before they write.
when_to_use: >
  "what's our voice", "how should we sound", "write down our tone", "our key messages", "words we
  never use", "does this sound like us", "is this on brand". SKIP to write or rewrite a page (use
  copywriting) and for logo, color or visual identity work.
metadata:
  version: 1.0.0
---

# Brand voice

One file holds how this brand sounds: `brand/voice.md`, tracked in the project. This skill writes
it, keeps it current and checks drafts against it. `copywriting` reads it before writing a page and
`campaign` reads it before planning one, so a decision made once is not asked again.

Three jobs. Pick by what the person asked:

| They want to | Do |
| --- | --- |
| set down the voice, or `brand/voice.md` does not exist | [Record](#record) |
| know whether a draft sounds like the brand | [Check](#check) |
| change a trait, a message or a banned phrase | [Change](#change) |

## Record

1. **Read what exists before asking.** Look for `brand/voice.md`, then for material that already
   shows the voice: the site's homepage and about page, the three most recent published posts, a
   product-marketing file (`.agents/product-marketing.md`, `.claude/product-marketing.md`). Draft
   from that material.
2. **Ask only for what the material does not answer**, one question at a time, each with the
   answer you would propose from what you read:
   - Who reads this brand, in their own words?
   - Three to five traits of the voice. For each: what it means here, and what it is not.
   - Up to five key messages. For each: the claim, and the proof behind it (a number, a customer,
     a fact). A message with no proof is recorded as *unproven*, never invented.
   - Phrases the brand never uses, and what to write instead.
   - One passage that sounds exactly right and one that sounds wrong.
3. **Write `brand/voice.md`** from `references/voice-template.md`. Keep every section heading: the
   other skills find their input by heading. Leave a section's body as `_Not decided yet._` when the
   person has not decided; do not fill it with a guess.
4. **Send it for review** the way any piece is ([Change](#change), step 2 onward).

## Check

Input: a draft (a file, or pasted text) and `brand/voice.md`. If the file does not exist, say so
and offer to record it; do not check against an assumed voice.

Report in this order, quoting the draft:

1. **Banned phrasings found** — each with its line, the phrase, and the replacement the file gives.
2. **Claims that contradict or go beyond a key message** — the sentence, the message it conflicts
   with, and whether the file holds proof for it.
3. **Off-voice passages** — at most five, the worst first, each with the trait it breaks and a
   rewrite.
4. **Verdict** — `on voice`, `on voice after the fixes above`, or `needs a rewrite`, in one line.

A draft with none of the three is reported as `on voice`, in one line. Do not add praise or
general writing advice: `copywriting` and the Editor own those.

## Change

The voice file is shared, so a change to it is reviewed like any piece of work.

1. Say what changes and why in one sentence, and confirm it with the person.
2. Record the work and start it:

   ```bash
   cckit task new --kind brand "Voice: <what changes>"
   cckit task start <id>
   ```

   In a project that tracks work in GitHub issues, use
   `cckit new --role editor --kind brand "<title>"` and `cckit start <issue>` instead.
3. Edit `brand/voice.md` in the folder `start` printed. Add one line to its `## Changes` section:
   the date, what changed, who decided.
4. Send it for review: `cckit task finish <id> "<what changed>" --all` (or
   `cckit pr <issue> "<what changed>"`). Give the person the link. The new voice applies once the
   review is approved and merged; until then drafts are checked against the current file.

## Rules

- **The file wins over memory.** Read `brand/voice.md` every time; do not rely on what an earlier
  conversation said the voice was.
- **Never invent proof.** A key message records the proof the person gave, or the word *unproven*.
- **A banned phrase needs a replacement.** "Never say X" with nothing to say instead produces
  drafts that dodge the idea. Ask for the replacement.
- **Keep it short.** A voice file over two pages is not read. Cut an example before a rule.
