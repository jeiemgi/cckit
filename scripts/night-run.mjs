export const meta = {
  name: 'night-run',
  description: 'Run an approved effort plan unattended, wave by wave, under a runtime-enforced token budget',
  whenToUse: 'Unattended execution of approved waves, launched by the kit-autopilot captain with a +N budget',
  phases: [
    { title: 'Preflight', detail: 'refuse a closed issue, a non-effort, or a held effort' },
    { title: 'Execute', detail: 'one implementer per effort, no wider than the effort WIP limit (max 4)' },
    { title: 'Verify', detail: 'independent gate + always-human floor read' },
    { title: 'Merge', detail: 'close each verified effort' },
    { title: 'Stop check', detail: 'the grant command after a wave; the gate on the base branch at the end' },
  ],
}

/* global agent, pipeline, log, budget, args -- the Workflow runtime injects these */

// The night engine. A Workflow script is the runtime that enforces the caps a prompt cannot: the
// token budget is `budget.total` (a +N directive), and concurrency, wave order and stop are code here.
// args: { waves: number[][], gate?: string, wipLimit?: number,
//         grant?: { waivers?: string[], stopCommand?: string,
//                   extraFloors?: {[name]: description}, neverWaivable?: string[] },
//         maxConcurrent?: number, waveReserve?: number, refuseLabels?: string[] }
// `scripts/night-grant.sh read <issue>` builds these args from the owner's night grant + the kit
// config. APPROVAL is that grant: the owner names each effort in `waves`, in a comment only the
// owner can write. There is no second approval marker on the effort itself.
//
// WAVE ORDER. Waves are dependency-ordered, so a wave that did not fully merge ends the run: the
// next wave would build on a base that lacks a parked or refused predecessor.
//
// WIP. Every executor runs `cckit effort start`, which refuses a NEW effort once `effort.wipLimit`
// (default 2) effort branches exist. The engine therefore runs no wider than `wipLimit`, and an
// effort that parked keeps its branch, so it takes a slot from the rest of its wave.
// Returns the wake report data; the captain (kit-autopilot) renders it and decides what follows.

const HARD_CONCURRENCY = 4 // one usage pool per account: a wide fan-out can spend a window in minutes
const BASE_NEVER_WAIVABLE = ['workflows', 'cost', 'secret']
const STANDING_WAIVERS = ['security-prose'] // a security/* diff that changes prose only
const BASE_FLOORS = {
  lockfile: 'the lockfile or a package manifest',
  auth: 'authentication or authorization code',
  'security-code': 'a security/* branch that changes any non-prose file',
  'security-prose': 'a security/* branch that changes prose only',
  workflows: 'CI workflow files (.github/workflows/** or equivalent)',
  cost: 'scaling, a paid resource, or a plan change',
  secret: 'a value only the owner can provide',
}

const waves = Array.isArray(args?.waves) ? args.waves.filter((w) => Array.isArray(w) && w.length) : []
const grant = args?.grant ?? {}
const floors = { ...BASE_FLOORS, ...(grant.extraFloors ?? {}) }
const neverWaivable = [...BASE_NEVER_WAIVABLE, ...(grant.neverWaivable ?? [])]
const waivers = new Set([...(grant.waivers ?? []), ...STANDING_WAIVERS])
const DEFAULT_WIP_LIMIT = 2 // effort.wipLimit's default (scripts/lib/effort-ops.sh, _eff_wip_limit)
const wipLimit = Number.isInteger(args?.wipLimit) && args.wipLimit >= 1 ? args.wipLimit : DEFAULT_WIP_LIMIT
const concurrency = Math.max(1, Math.min(args?.maxConcurrent ?? HARD_CONCURRENCY, HARD_CONCURRENCY, wipLimit))
const waveReserve = args?.waveReserve ?? 150_000
const refuseLabels = Array.isArray(args?.refuseLabels) ? args.refuseLabels : [] // night.refuseLabels
const gate = args?.gate ?? "the gate commands in the project's delegation brief"

const efforts = []
const report = (stop, reason = '') => ({
  stop,
  reason,
  efforts,
  spent: budget.spent(),
  total: budget.total,
})

if (budget.total === null) {
  return report('refused', 'no token budget: launch with a +N directive (the grant budget)')
}
if (!waves.length) return report('refused', 'no approved waves in args.waves')

const PREFLIGHT = {
  type: 'object',
  properties: {
    ok: { type: 'boolean' },
    labels: { type: 'array', items: { type: 'string' } },
    reason: { type: 'string' },
  },
  required: ['ok', 'labels', 'reason'],
}
const EXECUTE = {
  type: 'object',
  properties: {
    prUrl: { type: 'string' },
    branch: { type: 'string' },
    blocker: { type: 'string' },
  },
  required: ['prUrl', 'branch', 'blocker'],
}
const VERIFY = {
  type: 'object',
  properties: {
    gate: { type: 'string', enum: ['PASS', 'FAIL'] },
    floors: { type: 'array', items: { type: 'string', enum: Object.keys(floors) } },
  },
  required: ['gate', 'floors'],
}
const MERGE = {
  type: 'object',
  properties: { merged: { type: 'boolean' }, detail: { type: 'string' } },
  required: ['merged', 'detail'],
}
const STOP = {
  type: 'object',
  properties: { passed: { type: 'boolean' }, detail: { type: 'string' } },
  required: ['passed', 'detail'],
}

const BRIEF =
  "Read the project's delegation brief first if it has one. You run unattended inside a night " +
  'run: never ask a question, never confirm a destructive prompt, never take a cost action, and ' +
  'never open a review page (run every `cckit page` command with `CCKIT_HEADLESS=1`, so it ' +
  'prints to the terminal). Return only the schema.'

const preflightPrompt = (n) =>
  `${BRIEF}\nRead effort #${n}: \`gh issue view ${n} --json labels,state\`. ok=false when it ` +
  'is closed or lacks the `effort` label. Return every label name verbatim; reason names what ' +
  'is missing.'

const executePrompt = (n) =>
  `${BRIEF}\nYou implement effort #${n}, an approved plan, under the kit-autopilot plan-mode ` +
  `contract. Start or reuse its worktree (\`cckit effort start ${n}\`). Build each open sub-issue ` +
  `in order, one commit per sub. Run ${gate}, open the ONE effort PR with /kit-effort-pr ${n}, ` +
  'and never merge. Never pass `--force` and never set `KIT_FORCE` or `EFFORT_WIP_LIMIT`: when ' +
  '`cckit effort start` refuses on the WIP limit, stop and report that refusal as the blocker. ' +
  'blocker is empty unless you stopped on a genuine blocker: an unresolvable ' +
  'conflict, an ambiguity the plan is silent on, a secret only the owner has, a cost, or that ' +
  'WIP refusal.'

const floorList = Object.entries(floors)
  .map(([name, what]) => `${name} (${what})`)
  .join(', ')

const verifyPrompt = (n, branch) =>
  `${BRIEF}\nIndependently verify effort #${n} on branch \`${branch}\`; do not trust the ` +
  `implementer. In a fresh worktree at its head run ${gate} and report PASS or FAIL. Then read ` +
  'the diff against the base branch and list every always-human floor it trips: ' +
  `${floorList}.`

const mergePrompt = (n) =>
  `${BRIEF}\nEffort #${n} is verified and approved. Run /kit-effort-close ${n}: it merges the ` +
  'effort PR, closes the parent and its subs, and garbage-collects. merged=true only when the PR ' +
  'state reads MERGED afterwards.'

// Two separate checks, never one standing in for the other: the grant's stop command ends the
// night early, the gate is what "the base branch is green" means.
const stopPrompt = () =>
  `${BRIEF}\nFrom a worktree at the base branch head run: ${grant.stopCommand}\npassed = exit code 0.`
const gatePrompt = () =>
  `${BRIEF}\nIn a fresh worktree at the base branch head run ${gate}. passed = all green.`

function decide(verdict) {
  if (verdict.gate !== 'PASS') return { status: 'parked', reason: 'gate FAIL on the effort branch' }
  const never = verdict.floors.filter((f) => neverWaivable.includes(f))
  if (never.length) return { status: 'parked', reason: `never-waivable floor: ${never.join(', ')}` }
  const open = verdict.floors.filter((f) => !waivers.has(f))
  if (open.length) return { status: 'parked', reason: `floor not waived by the grant: ${open.join(', ')}` }
  return null
}

async function runEffort(n) {
  const entry = { effort: n, status: 'pending', reason: '', prUrl: '' }
  efforts.push(entry)
  const lost = () => {
    entry.status = 'unavailable'
    entry.reason = 'agent returned nothing (usage limit or API error)'
    return entry
  }

  const pre = await agent(preflightPrompt(n), {
    label: `preflight:${n}`,
    phase: 'Preflight',
    schema: PREFLIGHT,
    effort: 'low',
  })
  if (!pre) return lost()
  const refusedBy = pre.labels.filter((l) => refuseLabels.includes(l))
  if (!pre.ok || refusedBy.length) {
    entry.status = 'refused'
    entry.reason = refusedBy.length ? `carries ${refusedBy.join(', ')}` : pre.reason
    return entry
  }

  const exec = await agent(executePrompt(n), { label: `execute:${n}`, phase: 'Execute', schema: EXECUTE })
  if (!exec) return lost()
  entry.prUrl = exec.prUrl
  if (exec.blocker) {
    entry.status = 'parked'
    entry.reason = exec.blocker
    return entry
  }

  const verdict = await agent(verifyPrompt(n, exec.branch), {
    label: `verify:${n}`,
    phase: 'Verify',
    schema: VERIFY,
  })
  if (!verdict) return lost()
  const parked = decide(verdict)
  if (parked) return Object.assign(entry, parked)

  const merged = await agent(mergePrompt(n), { label: `merge:${n}`, phase: 'Merge', schema: MERGE })
  if (!merged) return lost()
  entry.status = merged.merged ? 'merged' : 'parked'
  entry.reason = merged.merged ? '' : merged.detail
  return entry
}

async function stopCheck() {
  const verdict = await agent(stopPrompt(), { label: 'stop', phase: 'Stop check', schema: STOP })
  return verdict?.passed === true
}

async function gateCheck() {
  const verdict = await agent(gatePrompt(), { label: 'gate', phase: 'Stop check', schema: STOP })
  return verdict?.passed === true
}

const tag = (e) => `#${e.effort} ${e.status}`
let stopCommandFailed = false

for (let w = 0; w < waves.length; w++) {
  if (budget.remaining() < waveReserve) {
    return report('budget', `${budget.remaining()} tokens left, a wave reserves ${waveReserve}`)
  }
  const wave = waves[w]
  log(`wave ${w + 1}/${waves.length}: ${wave.map((n) => `#${n}`).join(' ')}`)

  // Groups of at most `concurrency`, each a pipeline. An effort of this wave that started and did
  // not merge still holds its effort branch, so it takes a WIP slot from the groups after it.
  const first = efforts.length
  for (let i = 0; i < wave.length; ) {
    const held = efforts.slice(first).filter((e) => e.status !== 'merged' && e.status !== 'refused').length
    const slots = concurrency - held
    if (slots <= 0) {
      for (const n of wave.slice(i)) {
        efforts.push({
          effort: n,
          status: 'skipped',
          reason: `no WIP slot: ${held} unmerged effort(s) of this wave hold the limit of ${concurrency}`,
          prUrl: '',
        })
      }
      break
    }
    const group = wave.slice(i, i + slots)
    i += group.length
    await pipeline(group, (n) => runEffort(n))
    if (efforts.some((e) => e.status === 'unavailable' || e.status === 'pending')) {
      return report('usage-limit', `wave ${w + 1} lost an agent; resume this run after the reset`)
    }
  }

  const unmerged = efforts.slice(first).filter((e) => e.status !== 'merged')
  if (unmerged.length) {
    const later = waves.length - (w + 1)
    return report(
      'blocked',
      `wave ${w + 1} did not fully merge (${unmerged.map(tag).join(', ')})` +
        (later ? `; ${later} later wave(s) were not started because they build on it` : ''),
    )
  }

  if (grant.stopCommand) {
    if (await stopCheck()) return report('done', `stop command passed after wave ${w + 1}`)
    stopCommandFailed = true
  }
}

// Every wave merged. "Green" here is the gate, whatever the grant's stop command said.
const note = stopCommandFailed ? '; the stop command did not pass' : ''
return (await gateCheck())
  ? report('done', `every approved wave merged and the base branch gate is green${note}`)
  : report('blocked', `every wave merged but the base branch gate is red${note}`)
