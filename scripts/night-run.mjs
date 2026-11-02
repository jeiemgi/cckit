export const meta = {
  name: 'night-run',
  description: 'Run an approved effort plan unattended, wave by wave, under a runtime-enforced token budget',
  whenToUse: 'Unattended execution of approved waves, launched by the kit-autopilot captain with a +N budget',
  phases: [
    { title: 'Preflight', detail: 'refuse efforts that are not approved' },
    { title: 'Execute', detail: 'one implementer per effort, at most 4 at once' },
    { title: 'Verify', detail: 'independent gate + always-human floor read' },
    { title: 'Merge', detail: 'close each verified effort' },
    { title: 'Stop check', detail: 'the grant command, or the base branch green' },
  ],
}

/* global agent, pipeline, log, budget, args -- the Workflow runtime injects these */

// The night engine. A Workflow script is the runtime that enforces the caps a prompt cannot: the
// token budget is `budget.total` (a +N directive), and concurrency, stall and stop are code here.
// args: { waves: number[][], gate?: string,
//         grant?: { waivers?: string[], stopCommand?: string,
//                   extraFloors?: {[name]: description}, neverWaivable?: string[] },
//         maxConcurrent?: number, stallLimit?: number, waveReserve?: number,
//         refuseLabels?: string[] }
// `scripts/night-grant.sh read <issue>` builds these args from the night grant + kit.config.json.
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
const concurrency = Math.max(1, Math.min(args?.maxConcurrent ?? HARD_CONCURRENCY, HARD_CONCURRENCY))
const stallLimit = args?.stallLimit ?? 2
const waveReserve = args?.waveReserve ?? 150_000
const refuseLabels = args?.refuseLabels ?? ['grill:assumed']
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
  'return only the schema.'

const preflightPrompt = (n) =>
  `${BRIEF}\nRead effort #${n}: \`gh issue view ${n} --json labels,body,state\`. ok=false when it ` +
  'is closed, lacks the `effort` label, or its body has neither a `## Grilling` nor a `## Assumed` ' +
  'section. Return every label name verbatim; reason names what is missing.'

const executePrompt = (n) =>
  `${BRIEF}\nYou implement effort #${n}, an approved plan, under the kit-autopilot plan-mode ` +
  `contract. Start or reuse its worktree (\`cckit effort start ${n}\`). Build each open sub-issue ` +
  `in order, one commit per sub. Run ${gate}, open the ONE effort PR with /kit-effort-pr ${n}, ` +
  'and never merge. blocker is empty unless you stopped on a genuine blocker: an unresolvable ' +
  'conflict, an ambiguity the plan is silent on, a secret only the owner has, or a cost.'

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

const stopPrompt = () =>
  grant.stopCommand
    ? `${BRIEF}\nFrom a worktree at the base branch head run: ${grant.stopCommand}\npassed = exit code 0.`
    : `${BRIEF}\nIn a fresh worktree at the base branch head run ${gate}. passed = all green.`

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

let stalled = 0
for (let w = 0; w < waves.length; w++) {
  if (budget.remaining() < waveReserve) {
    return report('budget', `${budget.remaining()} tokens left, a wave reserves ${waveReserve}`)
  }
  log(`wave ${w + 1}/${waves.length}: ${waves[w].map((n) => `#${n}`).join(' ')}`)

  // Groups of `concurrency`, each a pipeline, so no more than 4 implementers share the pool at once.
  const before = efforts.filter((e) => e.status === 'merged').length
  for (let i = 0; i < waves[w].length; i += concurrency) {
    await pipeline(waves[w].slice(i, i + concurrency), (n) => runEffort(n))
  }

  if (efforts.some((e) => e.status === 'unavailable' || e.status === 'pending')) {
    return report('usage-limit', `wave ${w + 1} lost an agent; resume this run after the reset`)
  }
  const mergedThisWave = efforts.filter((e) => e.status === 'merged').length - before
  stalled = mergedThisWave ? 0 : stalled + 1
  if (stalled >= stallLimit) return report('stall', `${stalled} waves in a row merged nothing`)

  if (grant.stopCommand && (await stopCheck())) {
    return report('done', `stop command passed after wave ${w + 1}`)
  }
}

if (efforts.every((e) => e.status === 'merged')) {
  return (await stopCheck())
    ? report('done', 'every approved wave merged and the base branch is green')
    : report('blocked', 'every wave merged but the base branch gate is red')
}
return report('blocked', 'waves finished with parked or refused efforts')
