# Stage: plan — an effort with Specs, in waves, inside this week's sprint

Input: a goal with a confirmed Grilling record. Output: one effort issue whose subs each carry a
`## Spec`, a wave order in its Scope, and the sprint it lands in named in its body.

## 1. The sprint

A sprint is one week, Monday to Monday, named after its ISO week. Find it, and open it when the
forge has no milestone for it yet (re-running is safe):

```bash
cckit effort sprint name                                # 2026-W48
cckit effort sprint open --goal "<the one outcome of the week>"
cckit effort sprint list                                # open sprints, open and closed counts
```

An effort planned for next week passes a day of that week: `--sprint=2026-11-30`.

## 2. Cut the subs

- **Vertical slices.** Every sub is demoable on its own, through every layer it needs.
- **Expand–contract** for a wide refactor: add beside, move the callers, remove. The effort stays
  mergeable after every sub.
- **Each sub has a Spec:** what done means, as a checkable list. A sub nobody can check is
  not cut small enough. End an item only a person can accept with `(needs a yes)`; every report
  lists it under Waiting for a yes.
- **Waves.** Subs that touch disjoint files and block nothing run in the same wave; a sub that
  needs another's output goes in a later wave. Sequential subs are one wave each.

## 3. File the effort

The parent first, with its Spec, the Grilling record and the sprint; then one sub per slice, in
wave order, each with its own Spec:

```bash
cckit effort new --spec-file spec.md --grilling-file grilling.md --sprint \
  --scope "Wave 1: <a>, <b> (parallel). Wave 2: <c> (needs <a>)." "<name>"
cckit effort sub <N> "<sub name>" --spec "<item>; <item>" --body "<one line: what and why>"
cckit effort chain <a> <c>                              # a native blocked_by edge per dependency
```

`--sprint` adds a `## Sprint` section naming the week and its bounds, and puts the parent on the
sprint's milestone. `effort new` refuses a parent without a Spec or with a Grilling record that is
not one, before anything is written.

## 4. Check the wave order

```bash
cckit effort plan --issues --effort <N>     # the subs in dependency order, one wave per line
```

The verb's waves and the Scope must agree. When they do not, the Scope is wrong or an edge is
missing: fix it before orchestrating.

## 5. Report

Write the step report in the order Status · Done · Waiting for a yes · Numbers · Failing or risky ·
Open questions · Next step (`references/step-report.md`), then post its trail comment:

```bash
cckit agent receipt <N> --report .cckit/reports/<file>.md
```

Numbers: subs filed, waves, the sprint's open and closed counts. Waiting for a yes: any sub that
adds cost, and the plan itself when the owner asked to see it first.
