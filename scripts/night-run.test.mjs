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
  const stats = { maxInFlight: 0 }
  const budget = {
    total,
    spent: () => spent,
    remaining: () => (total === null ? Infinity : Math.max(0, total - spent)),
  }
  const agent = async (prompt, opts = {}) => {
    const [kind, id] = (opts.label ?? '').split(':')
    calls.push(opts.label)
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
    stats,
  }))
}

const green = {
  preflight: () => ({ ok: true, labels: ['effort'], reason: '' }),
  execute: (n) => ({ prUrl: `https://example.test/pull/${n}`, branch: `effort/${n}`, blocker: '' }),
  verify: () => ({ gate: 'PASS', floors: [] }),
  merge: () => ({ merged: true, detail: '' }),
  stop: () => ({ passed: true, detail: 'develop green' }),
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

test('never runs more than four agents at once, whatever the wave size', async () => {
  const { stats } = await run({
    args: { waves: [[1, 2, 3, 4, 5, 6, 7, 8, 9]], maxConcurrent: 16 },
    agents: green,
  })
  assert.ok(stats.maxInFlight <= 4, `saw ${stats.maxInFlight} agents in flight`)
})

test('refuses an effort still carrying grill:assumed', async () => {
  const { result, calls } = await run({
    args: { waves: [[1, 2]] },
    agents: {
      ...green,
      preflight: (n) =>
        n === 2
          ? { ok: true, labels: ['effort', 'grill:assumed'], reason: '' }
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

test('stops as stalled after two waves in a row with nothing merged', async () => {
  const { result } = await run({
    args: { waves: [[1], [2], [3]] },
    agents: { ...green, verify: () => ({ gate: 'FAIL', floors: [] }) },
  })
  assert.equal(result.stop, 'stall')
  assert.equal(statusOf(result, 3), undefined)
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
