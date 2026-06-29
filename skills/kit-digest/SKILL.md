---
name: kit-digest
description: Pre-digest long inputs (video transcripts, CI logs, big files, web pages) with the LOCAL model (mlx_lm.server) so the Claude session reads a short digest + pointer instead of the full content — token saving on every long read.
when_to_use: Before reading any long input into the session — a YouTube/video transcript, a CI failure log, a file or page over ~2k words. Especially "procesa este video/transcript/log". If the local server is down, the script says so — fall back to reading the original directly.
---

# kit-digest

Plugin-direct skill — the script + local-model helper resolve from `${CLAUDE_PLUGIN_ROOT}`.

## What it does

Delegates to `${CLAUDE_PLUGIN_ROOT}/scripts/kit-digest.sh` — acquires the text (file, URL, or
YouTube video via yt-dlp subtitles), chunks it (~2500 words), digests each chunk on the **local
model** (`${CLAUDE_PLUGIN_ROOT}/scripts/lib/kit-local.sh` → mlx_lm.server, $0 API), merges, and
prints a digest of at most ~1500 tokens plus a pointer to the original for selective deep-dives.

## Execution

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/kit-digest.sh" <path|url> [--focus "<topic>"] [--lang es|en]
```

| Flag | Description |
| --- | --- |
| `--focus "<topic>"` | Prioritize content related to a topic (e.g. `--focus "claude-kit"`) |
| `--lang es\|en` | Digest language (default `es`) |

## Exit codes — the fallback contract

| Code | Meaning | What Claude does |
| --- | --- | --- |
| 0 | Digest printed | Use the digest; read the original only for targeted deep-dives |
| 2 | Local server down | Tell the user (start command is in stderr) and read the original directly — current behavior, no digest |
| 1 | Input error (not found, no subs, empty) | Surface the error verbatim |

## Rules

- Never paste the full original into the session when the digest succeeded — the digest + pointer IS the deliverable of this skill.
- The digest must keep concrete numbers, names and issue/PR refs; if it visibly lost a critical detail, deep-dive the original section instead of re-digesting blind.
- Requires: `mlx_lm.server` running (see the `kit-local.sh` header), `yt-dlp` only for YouTube URLs.
