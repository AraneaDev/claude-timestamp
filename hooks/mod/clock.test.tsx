import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

const DIR = '/tmp/claude-timestamp-1000'

function world(on: On, flags: Record<string, string>, env: Record<string, string> = { UID: '1000' }) {
  const clock = mock.clock(on, { now: 1_700_000_100_000 })
  mock.env(on, { TMPDIR: '/tmp', HOME: '/home/u', ...env })
  on('session.id', () => ({ value: 's1' }))
  let runs = 0
  on('process.run', () => {
    runs += 1
    return { value: { exitCode: 0, stdout: '1000\n', stderr: '' } } as never
  })
  let reads = 0
  on('fs.read', ($, e) => {
    reads += 1
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
  // The engine's footer labels, beneath the plugin: the modes, joined.
  on('ui.render', { component: 'SessionMode' }, ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>{e.props.modes.join(' & ')}</Text>
  })
  on('session.end', ($, e) => ({ sessionId: e.sessionId }) as never)
  // While set, a read of the session's fallback start waits half a second:
  // how a tick is caught mid-draw.
  const hold = { on: false }
  on('state.get', async ($, e, next) => {
    if (hold.on && e.key === 'sessionStartedAt') await clock.sleep(500)
    return next(e)
  })
  return { clock, statuses, reads: () => reads, runs: () => runs, hold }
}

const ON = { enabled: 'on', live: 'on', start: '1700000000' }

// The clock as the footer shows it, beside a mode the engine already has.
async function footer($: any): Promise<string> {
  const ui = await $.ui.mount({
    plugin: 'timestamps',
    surface: 'terminal',
    component: 'SessionMode',
    props: { modes: ['focus'] },
  })
  const drawn = await ui.find({ type: 'Text' })
  await ui.unmount()
  return (drawn?.text ?? '').replace(/^focus( & )?/, '')
}
const done = (durationMs: number, agentId?: string) =>
  ({ answer: '', durationMs, isAborted: false, turnId: 't1', reason: 'answer', agentId }) as never

test('ticks every second during a turn, with the session total', async ($, on) => {
  const { clock, statuses } = world(on, ON)
  await $.turn.start({ text: 'hi', turnId: 't1' })
  await clock.advance(72_000)
  expect(await footer($)).toBe('⏱ 1m12s · session 2m52s')
})

test('holds the final duration after the turn completes', async ($, on) => {
  const { clock, statuses } = world(on, ON)
  await $.turn.start({ text: 'hi', turnId: 't1' })
  await clock.advance(5_000)
  await $.turn.complete(done(5_400))
  const held = await footer($)
  await clock.advance(10_000)
  expect(held).toBe('⏱ 5s · session 1m45s')
  expect(await footer($)).toBe(held)
})

test('the held figure rounds, as the engine writes the turn time', async ($, on) => {
  const { clock } = world(on, ON)
  await $.turn.start({ text: 'hi', turnId: 't1' })
  await clock.advance(5_000)
  await $.turn.complete(done(88_600))
  expect(await footer($)).toMatch(/^⏱ 1m29s /)
})

// A subagent's run raises turn.complete with its agentId, and no turn.start.
test("a subagent's completion does not stop the main clock", async ($, on) => {
  const { clock, statuses } = world(on, ON)
  await $.turn.start({ text: 'hi', turnId: 't1' })
  await clock.advance(10_000)
  await $.turn.complete(done(3_000, 'agent-1'))
  await clock.advance(2_000)
  expect(await footer($)).toBe('⏱ 12s · session 1m52s')
})

test('LIVE=off draws no clock', async ($, on) => {
  const { clock, statuses } = world(on, { ...ON, live: 'off' })
  await $.turn.start({ text: 'hi', turnId: 't1' })
  await clock.advance(5_000)
  expect(await footer($)).toBe('')
})

test("no .start: the session total counts from the mod's own session start", async ($, on) => {
  const { clock, statuses } = world(on, { enabled: 'on' })
  await $.session.start({ cwd: '/w', surface: null, isInteractive: true })
  await clock.advance(1_000)
  await $.turn.start({ text: 'hi', turnId: 't1' })
  await clock.advance(3_000)
  expect(await footer($)).toBe('⏱ 3s · session 4s')
})

test('LIVE=off: once the turn has started, nothing more is read', async ($, on) => {
  const w = world(on, { ...ON, live: 'off' })
  await $.turn.start({ text: 'hi', turnId: 't1' })
  const before = w.reads()
  await w.clock.advance(10_000)
  expect(w.reads()).toBe(before)
})

test('id -u runs once, however many turns tick', async ($, on) => {
  const w = world(on, ON, {})
  await $.turn.start({ text: 'hi', turnId: 't1' })
  await w.clock.advance(3_000)
  await $.turn.complete(done(3_000))
  await $.turn.start({ text: 'again', turnId: 't2' })
  await w.clock.advance(3_000)
  expect(await footer($)).toBe('⏱ 3s · session 1m46s')
  expect(w.runs()).toBe(1)
})

test('a missed turn.complete does not carry its start into the next turn', async ($, on) => {
  const w = world(on, ON)
  await $.turn.start({ text: 'hi', turnId: 't1' })
  await w.clock.advance(120_000)
  await $.turn.start({ text: 'again', turnId: 't2' })
  await w.clock.advance(5_000)
  expect(await footer($)).toMatch(/^⏱ 5s · /)
})

test('a tick still drawing when the turn ends does not replace the held figure', async ($, on) => {
  const w = world(on, { enabled: 'on' })
  await $.turn.start({ text: 'hi', turnId: 't1' })
  await w.clock.advance(4_000)
  w.hold.on = true
  await w.clock.advance(1_000)
  w.hold.on = false
  await $.turn.complete(done(7_000))
  await w.clock.advance(500)
  expect(await footer($)).toBe('⏱ 7s')
})

test('/clear starts the session total again', async ($, on) => {
  const w = world(on, { enabled: 'on' })
  await $.session.start({ cwd: '/w', surface: null, isInteractive: true })
  await w.clock.advance(100_000)
  await $.session.end({ reason: 'clear', sessionId: 's1', resume: {} } as never)
  await w.clock.advance(1_000)
  await $.turn.start({ text: 'hi', turnId: 't1' })
  await w.clock.advance(3_000)
  expect(await footer($)).toBe('⏱ 3s · session 4s')
})

test('the clock is a footer label, never a pinned status notice', async ($, on) => {
  const { clock, statuses } = world(on, ON)
  await $.turn.start({ text: 'hi', turnId: 't1' })
  await clock.advance(3_000)
  expect(await footer($)).toBe('⏱ 3s · session 1m43s')
  expect(statuses.filter(s => s !== undefined)).toEqual([])
})
