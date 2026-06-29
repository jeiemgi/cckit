# Browser debug (`cckit debug`) — optional capability

`cckit debug` gives an agent a token-efficient, scriptable browser-debug path — screenshots,
accessibility snapshots, console + network logs, Lighthouse — by driving
[chrome-devtools-axi](https://github.com/kunchenguid/chrome-devtools-axi) (Kun Chen). axi runs a
self-contained Chrome bridge and emits TOON-encoded output, so results stay compact in context.

## Optional + auto-detected

cckit is pure bash; axi needs Node + Chrome. So this is **not a hard dependency** — it is detected
at call time and degrades cleanly:

- Node/npx **and** Chrome present → `cckit debug` drives axi.
- Otherwise → it prints how to enable the capability and exits `0` (an unattended run is never
  hard-failed by a missing optional tool).

Check availability without running anything:

```sh
cckit debug --check
```

## Enabling it

```sh
npm i -g chrome-devtools-axi      # or rely on `npx -y chrome-devtools-axi` (Node present)
```

Override the command cckit invokes with `CCKIT_AXI=<command>` (e.g. a pinned version or a wrapper).

## Usage

```sh
cckit debug <axi-args...>         # forwarded verbatim to axi — see the axi docs for subcommands
```

Everything after `cckit debug` is passed straight through to axi, so cckit never has to track axi's
evolving subcommand surface.
