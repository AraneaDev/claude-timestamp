import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

const DIR = '/tmp/claude-timestamp-1000'

function world(on: On, flags: Record<string, string>) {
  const clock = mock.clock(on, { now: 1_700_000_100_000 })
  mock.env(on, { TMPDIR: '/tmp', UID: '1000', HOME: '/home/u' })
  on('session.id', () => ({ value: 's1' }))
  on('fs.read', ($, e) => {
    const name = e.path.startsWith(`${DIR}/s1.`) ? e.path.slice(`${DIR}/s1.`.length) : ''
    const text = flags[name]
    return text === undefined ? { deny: `ENOENT ${e.path}` } : { value: text }
  })
  const statuses: Array<string | undefined> = []
  on('ui.status', ($, e) => {
    statuses.push(e.text)
    return { value: undefined }
  })
  on('turn.start', ($, e) => ({ turnId: e.turnId }))
  on('turn.complete', () => ({ text: '' }))
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  return { clock, statuses }
}

const ON = { enabled: 'on', live: 'on', start: '1700000000' }
const done = (durationMs: number, agentId?: string) =>
  ({ answer: '', durationMs, isAborted: false, turnId: 't1', reason: 'answer', agentId }) as never

test('ticks every second during a turn, with the session total', async ($, on) => {
  const { clock, statuses } = world(on, ON)
  await $.turn.start({ text: 'hi', turnId: 't1' })
  await clock.advance(72_000)
  expect(statuses.at(-1)).toBe('⏱ 1m12s · session 2m52s')
})

test('holds the final duration after the turn completes', async ($, on) => {
  const { clock, statuses } = world(on, ON)
  await $.turn.start({ text: 'hi', turnId: 't1' })
  await clock.advance(5_000)
  await $.turn.complete(done(5_400))
  const held = statuses.at(-1)
  await clock.advance(10_000)
  expect(held).toBe('⏱ 5s · session 1m45s')
  expect(statuses.at(-1)).toBe(held)
})

test('a subagent turn neither restarts nor stops the main clock', async ($, on) => {
  const { clock, statuses } = world(on, ON)
  await $.turn.start({ text: 'hi', turnId: 't1' })
  await clock.advance(10_000)
  await $.turn.start({ text: 'sub', turnId: 't2' })
  await $.turn.complete(done(3_000, 'agent-1'))
  await clock.advance(2_000)
  expect(statuses.at(-1)).toBe('⏱ 12s · session 1m52s')
})

test('LIVE=off keeps the status line clear', async ($, on) => {
  const { clock, statuses } = world(on, { ...ON, live: 'off' })
  await $.turn.start({ text: 'hi', turnId: 't1' })
  await clock.advance(5_000)
  expect(statuses.filter(s => s !== undefined)).toEqual([])
})

test("no .start: the session total counts from the mod's own session start", async ($, on) => {
  const { clock, statuses } = world(on, { enabled: 'on' })
  await $.session.start({ cwd: '/w', surface: null, isInteractive: true })
  await clock.advance(1_000)
  await $.turn.start({ text: 'hi', turnId: 't1' })
  await clock.advance(3_000)
  expect(statuses.at(-1)).toBe('⏱ 3s · session 4s')
})
