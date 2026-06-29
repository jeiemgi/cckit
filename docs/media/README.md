# Demo media

[← Usage](../usage.md) · [README](../../README.md)

Terminal demos for the docs.

| File | Shows | How it's made |
| ---- | ----- | ------------- |
| `kit-onboarding.gif` | Onboarding **through the `claude` CLI** (`claude -p`) running the kit-init scaffold preview | **Real `claude` session** captured headless with asciinema, then **re-timed** for a watchable GIF (claude's ~16 s think-time → a short beat; burst output → streamed). Content is genuine, not faked. |
| `kit-init.gif` | the interactive `claude > /kit-init` onboarding with test values | **Illustrative re-creation** — the prompt + answer chips are mocked (plugin slash commands aren't available in `claude -p`, and the interactive TUI can't be keystroke-driven headlessly); the scaffold output is real `init.sh`. |
| `kit-dry-run.gif` | `init.sh --dry-run` printing the scaffold plan | Synthesized from the deterministic `--dry-run` output (it writes nothing). |
| `.onboarding-capture.cast` | the raw asciinema capture behind `kit-onboarding.gif` | source for re-rendering without another `claude` call |

> The `/kit-customize` and `/kit-contribute` slash commands are skills Claude runs **inside Claude
> Code**, not terminal programs, so they're documented in prose — not faked as terminal GIFs.

## Regenerate

```bash
# Onboarding GIF — re-render from the saved capture (no claude call):
ONB_CAST=docs/media/.onboarding-capture.cast bash docs/media/build-onboarding.sh
# …or capture a fresh real claude session (needs claude auth + an API call):
bash docs/media/build-onboarding.sh

# Deterministic CLI demos (dry-run, scaffold, help):
bash docs/media/build-demo.sh

# Illustrative interactive /kit-init clip (mocked chips + real scaffold output):
bash docs/media/build-kit-init.sh
```

To capture the **genuine interactive `/kit-init`** (which can't be done headlessly), record it in a
real terminal: `asciinema rec demo.cast`, run `claude`, type `/kit-init`, answer the chips, exit, then
`agg demo.cast demo.gif`.

Dependencies: `agg`, `jq`, `awk`, `bash` (+ `asciinema` and an authenticated `claude` to re-capture).
On macOS: `brew install agg jq asciinema`.

## Notes

- Use **CRLF** (`\r\n`) between output lines so the terminal returns to column 0 (LF-only staircases).
- Keep GIFs under ~1 MB so they embed well on GitHub.
- `build-onboarding.sh` records a real `claude` run and only re-times it; it never fabricates output.
