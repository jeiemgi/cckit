import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import test from 'node:test'

// The engine is a Workflow script: plain JS that the Workflow runtime evaluates with agent(),
// pipeline(), parallel(), phase(), log(), budget and args as globals. This harness evaluates the
// same text with those globals stubbed, so every unattended decision is exercised without a model.
const SOURCE = readFileSync(new URL('./night-run.mjs', import.meta.url), 'utf8').replace(
  /^export const meta =/m,
  'const meta =',
)
const AsyncFunction = Object.getPrototypeOf(async () => {}).constructor

function run({ args, total = 1_000_000, agents = {} }) {
  let spent = 0
  let inFlight = 0
  const calls = []
  const prompts = {}
  const stats = { maxInFlight: 0 }
  const budget = {
    total,
    spent: () => spent,
    remaining: () => (total === null ? Infinity : Math.max(0, total - spent)),
  }
  const agent = async (prompt, opts = {}) => {
    const [kind, id] = (opts.label ?? '').split(':')
    calls.push(opts.label)
    prompts[opts.label] = prompt
    inFlight++
    stats.maxInFlight = Math.max(stats.maxInFlight, inFlight)
    await new Promise((resolve) => setTimeout(resolve, 1))
    inFlight--
    spent += 10_000
    const handler = agents[kind]
    return handler ? handler(Number(id), prompt) : null
  }
  const parallel = async (thunks) =>
    Promise.all(thunks.map((t) => Promise.resolve().then(t).catch(() => null)))
  const pipeline = async (items, ...stages) =>
    Promise.all(
      items.map(async (item, index) => {
        let value = item
        for (const stage of stages) {
          try {
            value = await stage(value, item, index)
          } catch {
            return null
          }
        }
        return value
      }),
    )
  const body = new AsyncFunction(
    'agent',
    'parallel',
    'pipeline',
    'phase',
    'log',
    'budget',
    'args',
    SOURCE,
  )
  return body(agent, parallel, pipeline, () => {}, () => {}, budget, args).then((result) => ({
    result,
    calls,
    prompts,
    stats,
  }))
}

const green = {
  preflight: () => ({ ok: true, labels: ['effort'], reason: '' }),
  execute: (n) => ({ prUrl: `https://example.test/pull/${n}`, branch: `effort/${n}`, blocker: '' }),
  verify: () => ({ gate: 'PASS', floors: [] }),
  merge: () => ({ merged: true, detail: '' }),
  stop: () => ({ passed: true, detail: 'stop command exit 0' }),
  gate: () => ({ passed: true, detail: 'develop green' }),
}

const statusOf = (result, effort) => result.efforts.find((e) => e.effort === effort)?.status

test('refuses to start without a token budget', async () => {
  const { result, calls } = await run({ args: { waves: [[1]] }, total: null, agents: green })
  assert.equal(result.stop, 'refused')
  assert.match(result.reason, /budget/)
  assert.deepEqual(calls, [])
})

test('refuses an empty plan', async () => {
  const { result } = await run({ args: { waves: [] }, agents: green })
  assert.equal(result.stop, 'refused')
})

test('merges every approved wave and stops as done when develop is green', async () => {
  const { result } = await run({ args: { waves: [[1, 2], [3]] }, agents: green })
  assert.equal(result.stop, 'done')
  assert.deepEqual(
    result.efforts.map((e) => e.status),
    ['merged', 'merged', 'merged'],
  )
})

test('never runs more than four agents at once, whatever the wave size or the WIP limit', async () => {
  const { stats } = await run({
    args: { waves: [[1, 2, 3, 4, 5, 6, 7, 8, 9]], maxConcurrent: 16, wipLimit: 16 },
    agents: green,
  })
  assert.equal(stats.maxInFlight, 4)
})

test('runs no wider than the default effort WIP limit of 2 when args carry none', async () => {
  const { result, stats } = await run({ args: { waves: [[1, 2, 3, 4, 5, 6]] }, agents: green })
  assert.equal(stats.maxInFlight, 2)
  assert.equal(result.stop, 'done')
})

test('runs as wide as effort.wipLimit, and no wider', async () => {
  const { stats } = await run({ args: { waves: [[1, 2, 3, 4, 5, 6]], wipLimit: 3 }, agents: green })
  assert.equal(stats.maxInFlight, 3)
})

test('a parked effort keeps its WIP slot from the rest of its wave', async () => {
  const one = await run({
    args: { waves: [[1, 2, 3, 4]], wipLimit: 2 },
    agents: { ...green, verify: (n) => ({ gate: n === 1 ? 'FAIL' : 'PASS', floors: [] }) },
  })
  // #1 parked and holds a branch, so #3 and #4 run one at a time in the single slot left
  assert.deepEqual(
    one.result.efforts.map((e) => e.status),
    ['parked', 'merged', 'merged', 'merged'],
  )
  assert.ok(one.calls.indexOf('merge:3') < one.calls.indexOf('preflight:4'))

  const both = await run({
    args: { waves: [[1, 2, 3, 4]], wipLimit: 2 },
    agents: { ...green, verify: () => ({ gate: 'FAIL', floors: [] }) },
  })
  assert.equal(statusOf(both.result, 3), 'skipped')
  assert.equal(statusOf(both.result, 4), 'skipped')
  assert.match(both.result.efforts[2].reason, /WIP/)
  assert.ok(!both.calls.includes('preflight:3'))
})

test('the executor is told never to force past the WIP limit', async () => {
  const { prompts } = await run({ args: { waves: [[1]] }, agents: green })
  assert.match(prompts['execute:1'], /Never pass `--force`/)
  assert.match(prompts['execute:1'], /EFFORT_WIP_LIMIT/)
})

test('an effort created by `cckit effort new` passes preflight: no body section is demanded', async () => {
  const { result, prompts } = await run({
    args: { waves: [[1]] },
    // the labels effort_new applies; no grill:* label and no ## Grilling section exists in the kit
    agents: { ...green, preflight: () => ({ ok: true, labels: ['effort', 'ctx:M', 'flow:core'], reason: '' }) },
  })
  assert.equal(statusOf(result, 1), 'merged')
  assert.doesNotMatch(prompts['preflight:1'], /Grilling|Assumed/)
  assert.doesNotMatch(prompts['preflight:1'], /body/)
})

test('refuses an effort carrying a label the project holds out of night runs', async () => {
  const { result, calls } = await run({
    args: { waves: [[1, 2]], refuseLabels: ['hold'] },
    agents: {
      ...green,
      preflight: (n) =>
        n === 2
          ? { ok: true, labels: ['effort', 'hold'], reason: '' }
          : { ok: true, labels: ['effort'], reason: '' },
    },
  })
  assert.equal(statusOf(result, 1), 'merged')
  assert.equal(statusOf(result, 2), 'refused')
  assert.ok(!calls.includes('execute:2'))
})

test('parks an effort whose diff trips a floor the grant did not waive', async () => {
  const { result, calls } = await run({
    args: { waves: [[1]] },
    agents: { ...green, verify: () => ({ gate: 'PASS', floors: ['lockfile'] }) },
  })
  assert.equal(statusOf(result, 1), 'parked')
  assert.match(result.efforts[0].reason, /lockfile/)
  assert.ok(!calls.includes('merge:1'))
})

test('merges when the grant waives the tripped floor', async () => {
  const { result } = await run({
    args: { waves: [[1]], grant: { waivers: ['lockfile'] } },
    agents: { ...green, verify: () => ({ gate: 'PASS', floors: ['lockfile'] }) },
  })
  assert.equal(statusOf(result, 1), 'merged')
})

test('a never-waivable floor parks even when the grant lists it', async () => {
  for (const floor of ['workflows', 'cost', 'secret']) {
    const { result } = await run({
      args: { waves: [[1]], grant: { waivers: [floor] } },
      agents: { ...green, verify: () => ({ gate: 'PASS', floors: [floor] }) },
    })
    assert.equal(statusOf(result, 1), 'parked', floor)
  }
})

test('a project-declared never-waivable floor parks even when the grant lists it', async () => {
  const { result } = await run({
    args: {
      waves: [[1]],
      grant: { waivers: ['auth-dep'], extraFloors: { 'auth-dep': 'the auth library version' }, neverWaivable: ['auth-dep'] },
    },
    agents: { ...green, verify: () => ({ gate: 'PASS', floors: ['auth-dep'] }) },
  })
  assert.equal(statusOf(result, 1), 'parked')
})

test('a project-declared extra floor merges when the grant waives it', async () => {
  const { result } = await run({
    args: { waves: [[1]], grant: { waivers: ['build-config'], extraFloors: { 'build-config': 'the build pipeline config' } } },
    agents: { ...green, verify: () => ({ gate: 'PASS', floors: ['build-config'] }) },
  })
  assert.equal(statusOf(result, 1), 'merged')
})

test('a security branch with a prose-only diff merges without a waiver', async () => {
  const { result } = await run({
    args: { waves: [[1]] },
    agents: { ...green, verify: () => ({ gate: 'PASS', floors: ['security-prose'] }) },
  })
  assert.equal(statusOf(result, 1), 'merged')
})

test('parks on a red gate', async () => {
  const { result } = await run({
    args: { waves: [[1]] },
    agents: { ...green, verify: () => ({ gate: 'FAIL', floors: [] }) },
  })
  assert.equal(statusOf(result, 1), 'parked')
})

test('an agent lost mid-wave returns usage-limit so the captain can resume', async () => {
  const { result } = await run({
    args: { waves: [[1, 2], [3]] },
    agents: { ...green, execute: (n) => (n === 2 ? null : green.execute(n)) },
  })
  assert.equal(result.stop, 'usage-limit')
  assert.equal(statusOf(result, 2), 'unavailable')
  assert.equal(statusOf(result, 3), undefined)
})

test('a parked wave stops the run before the waves that depend on it', async () => {
  const { result, calls } = await run({
    args: { waves: [[12], [15], [16]] },
    agents: { ...green, verify: () => ({ gate: 'FAIL', floors: [] }) },
  })
  assert.equal(result.stop, 'blocked')
  assert.match(result.reason, /wave 1 did not fully merge \(#12 parked\)/)
  assert.match(result.reason, /2 later wave\(s\) were not started/)
  assert.equal(statusOf(result, 15), undefined)
  assert.ok(!calls.includes('preflight:15'))
  assert.ok(!calls.includes('gate'))
})

test('a partly merged wave stops the run too: one refused effort holds its dependents back', async () => {
  const { result, calls } = await run({
    args: { waves: [[1, 2], [3]] },
    agents: {
      ...green,
      preflight: (n) => ({ ok: n !== 2, labels: ['effort'], reason: n === 2 ? 'closed' : '' }),
    },
  })
  assert.equal(result.stop, 'blocked')
  assert.equal(statusOf(result, 1), 'merged')
  assert.equal(statusOf(result, 2), 'refused')
  assert.ok(!calls.includes('execute:3'))
})

test('the final check runs the gate, not the stop command, when every wave merged', async () => {
  const grant = { stopCommand: 'pnpm typecheck' }
  const failing = { ...green, stop: () => ({ passed: false, detail: 'exit 1' }) }

  const greenGate = await run({ args: { waves: [[1], [2]], gate: 'make check', grant }, agents: failing })
  assert.equal(greenGate.result.stop, 'done')
  assert.match(greenGate.result.reason, /gate is green; the stop command did not pass/)
  assert.equal(greenGate.calls.at(-1), 'gate')
  assert.match(greenGate.prompts.gate, /make check/)
  assert.doesNotMatch(greenGate.prompts.gate, /pnpm typecheck/)
  assert.doesNotMatch(greenGate.prompts.stop, /make check/)

  const redGate = await run({
    args: { waves: [[1], [2]], gate: 'make check', grant },
    agents: { ...failing, gate: () => ({ passed: false, detail: 'red' }) },
  })
  assert.equal(redGate.result.stop, 'blocked')
  assert.match(redGate.result.reason, /gate is red/)
})

test('without a stop command the stop agent never runs and the gate decides', async () => {
  const { result, calls } = await run({
    args: { waves: [[1]] },
    agents: { ...green, gate: () => ({ passed: false, detail: 'red' }) },
  })
  assert.equal(result.stop, 'blocked')
  assert.ok(!calls.includes('stop'))
})

test('the grant stop command ends the night early when it passes', async () => {
  const { result, calls } = await run({
    args: { waves: [[1], [2]], grant: { stopCommand: 'scripts/lib/ontology-enforce.sh' } },
    agents: green,
  })
  assert.equal(result.stop, 'done')
  assert.ok(!calls.includes('execute:2'))
})

test('stops before a wave the remaining budget cannot cover', async () => {
  const { result, calls } = await run({
    // wave 1 spends 40k of 90k; the 50k left is under the 55k a wave reserves
    args: { waves: [[1], [2]], waveReserve: 55_000 },
    total: 90_000,
    agents: green,
  })
  assert.equal(result.stop, 'budget')
  assert.ok(!calls.includes('execute:2'))
})
