import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

const DIR = '/tmp/claude-timestamp-1000'
const SURFACES = ['terminal', 'desktop'] as const
const BAND = {
  component: 'AbovePrompt' as const,
  props: { hasSurvey: false, isWorking: true, maxRows: 10, bodyColumns: 80, scroll: { offset: 0, bodyRows: 10 }, view: {} },
}
const TSV = ['1\tapp\tnpm test\t40000\tok', '2\tapp\tnpm test\t40000\tok', '3\tapp\tnpm test\t40000\tok'].join('\n')

function world(on: On, flags: Record<string, string> = {}) {
  const clock = mock.clock(on, { now: 1_700_000_000_000 })
  mock.env(on, { TMPDIR: '/tmp', UID: '1000', HOME: '/home/u' })
  const files: Record<string, string> = {
    [`${DIR}/s1.enabled`]: 'on',
    [`${DIR}/s1.live`]: 'on',
    [`${DIR}/s1.livetool`]: '60',
    [`${DIR}/s1.project`]: 'app',
    [`${DIR}/s1.cmdmem`]: 'on',
    '/home/u/.claude/claude-timestamp-commands.tsv': TSV,
    ...Object.fromEntries(Object.entries(flags).map(([k, v]) => [`${DIR}/s1.${k}`, v])),
  }
  on('session.id', () => ({ value: 's1' }))
  let reads = 0
  on('fs.read', ($, e) => {
    reads += 1
    const text = files[e.path]
    return text === undefined ? { deny: `ENOENT ${e.path}` } : { value: text }
  })
  on('ui.status', () => ({ value: undefined }))
  on('ui.invalidate', () => ({ value: undefined }))
  // The engine's own band, beneath the plugin: drawn when the plugin passes.
  on('ui.render', { component: 'AbovePrompt' }, ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>engine band</Text>
  })
  // Each tool runs until the test finishes it.
  on('turn.complete', () => ({ text: '' }))
  on('tool.check', () => ({ decision: 'ask' as const }))
  // How many state writes to refuse, and which: the module's own bookkeeping
  // failing must never stop or repeat the tool.
  const refuse = { from: Infinity, count: 0 }
  let writes = 0
  on('state.set', ($, e, next) => {
    writes += 1
    if (writes >= refuse.from && writes < refuse.from + refuse.count) return { deny: 'refused by the test' }
    return next(e)
  })
  let ran = 0
  const finish: Record<string, () => void> = {}
  const fail: Record<string, () => void> = {}
  on('tool.call', async ($, e) => {
    ran += 1
    await new Promise<void>((resolve, reject) => {
      finish[e.tool_use_id ?? ''] = resolve
      fail[e.tool_use_id ?? ''] = () => reject(new Error('boom'))
    })
    return { result: {} } as never
  })
  // Ends a running call; throws when the test names a call that never started.
  const end = (which: Record<string, () => void>, id: string) => {
    const act = which[id]
    if (!act) throw new Error(`no running call ${id}`)
    act()
  }
  return {
    clock,
    finish: (id: string) => end(finish, id),
    fail: (id: string) => end(fail, id),
    reads: () => reads,
    ran: () => ran,
    writes: () => writes,
    refuse,
  }
}

async function bandText($: any, surface: (typeof SURFACES)[number]) {
  const ui = await $.ui.mount({ plugin: 'claude-timestamp', surface, ...BAND })
  const mine = await ui.find({ type: 'Text', text: / · / })
  await ui.unmount()
  return mine?.text
}

test('quiet below the threshold, shown above it, with the usual time', async ($, on) => {
  const { clock, finish } = world(on)
  const call = $.tool.call({ tool: 'Bash', command: 'npm test', tool_use_id: 'a' } as never)
  await clock.advance(30_000)
  for (const s of SURFACES) expect(await bandText($, s)).toBeUndefined()
  await clock.advance(31_000)
  for (const s of SURFACES) expect(await bandText($, s)).toBe('npm test · 1m01s · usually ~40s')
  finish('a')
  await call
  for (const s of SURFACES) expect(await bandText($, s)).toBeUndefined()
})

test('an unknown command waits for SLOW_TOOL_AFTER', async ($, on) => {
  const { clock, finish } = world(on, { livetool: '20' })
  const call = $.tool.call({ tool: 'Bash', command: 'make', tool_use_id: 'a' } as never)
  await clock.advance(19_000)
  expect(await bandText($, 'terminal')).toBeUndefined()
  await clock.advance(2_000)
  expect(await bandText($, 'terminal')).toBe('make · 21s')
  finish('a')
  await call
})

test('several running: the longest slow one, plus a count', async ($, on) => {
  const { clock, finish } = world(on)
  const one = $.tool.call({ tool: 'Bash', command: 'make', tool_use_id: 'a' } as never)
  await clock.advance(10_000)
  const two = $.tool.call({ tool: 'Read', file_path: '/x', tool_use_id: 'b' } as never)
  await clock.advance(55_000)
  expect(await bandText($, 'terminal')).toBe('make · 1m05s · +1 more')
  finish('a')
  await one
  expect(await bandText($, 'terminal')).toBeUndefined()
  finish('b')
  await two
})

test('a background command never shows', async ($, on) => {
  const { clock, finish } = world(on)
  const call = $.tool.call({ tool: 'Bash', command: 'npm test', run_in_background: true, tool_use_id: 'a' } as never)
  await clock.advance(120_000)
  expect(await bandText($, 'terminal')).toBeUndefined()
  finish('a')
  await call
})

test('a tool that errors beneath still leaves the band', async ($, on) => {
  const { clock, fail } = world(on)
  const call = $.tool.call({ tool: 'Bash', command: 'make', tool_use_id: 'a' } as never).catch(() => undefined)
  await clock.advance(70_000)
  expect(await bandText($, 'terminal')).toBe('make · 1m10s')
  fail('a')
  await call
  expect(await bandText($, 'terminal')).toBeUndefined()
})

test('LIVE=off: the engine band is drawn and the tool still runs', async ($, on) => {
  const { clock, finish } = world(on, { live: 'off' })
  const call = $.tool.call({ tool: 'Bash', command: 'npm test', tool_use_id: 'a' } as never)
  await clock.advance(90_000)
  const ui = await $.ui.mount({ plugin: 'claude-timestamp', surface: 'terminal', ...BAND })
  expect((await ui.find({ type: 'Text', text: /engine band/ }))?.text).toBe('engine band')
  await ui.unmount()
  finish('a')
  await expect(call).resolves.toBeDefined()
})

test('a short call costs no reads when the band is drawn', async ($, on) => {
  const w = world(on)
  const call = $.tool.call({ tool: 'Bash', command: 'npm test', tool_use_id: 'a' } as never)
  await w.clock.advance(5_000)
  const before = w.reads()
  expect(await bandText($, 'terminal')).toBeUndefined()
  expect(w.reads()).toBe(before)
  w.finish('a')
  await call
})

test('a question put to the person never shows', async ($, on) => {
  const w = world(on)
  const call = $.tool.call({ tool: 'AskUserQuestion', questions: [], tool_use_id: 'q' } as never)
  await w.clock.advance(120_000)
  expect(await bandText($, 'terminal')).toBeUndefined()
  w.finish('q')
  await call
})

test('a call that waited on a permission prompt never shows', async ($, on) => {
  const w = world(on)
  const call = $.tool.call({ tool: 'Bash', command: 'npm test', tool_use_id: 'a' } as never)
  // In a session tool.check runs inside the call's next, after its hook began.
  await w.clock.settle()
  await $.tool.check({ tool: 'Bash', input: { command: 'npm test' }, tool_use_id: 'a' } as never)
  await w.clock.advance(120_000)
  expect(await bandText($, 'terminal')).toBeUndefined()
  w.finish('a')
  await call
})

test('a call left behind is dropped when the main turn completes', async ($, on) => {
  const w = world(on)
  void $.tool.call({ tool: 'Bash', command: 'make', tool_use_id: 'a' } as never).catch(() => undefined)
  await w.clock.advance(70_000)
  expect(await bandText($, 'terminal')).toBe('make · 1m10s')
  await $.turn.complete({ answer: '', durationMs: 70_000, isAborted: true, turnId: 't1', reason: 'aborted' } as never)
  expect(await bandText($, 'terminal')).toBeUndefined()
})

test('a refused first state write still runs the tool, once', async ($, on) => {
  const w = world(on)
  w.refuse.from = 1
  w.refuse.count = 1
  const call = $.tool.call({ tool: 'Bash', command: 'make', tool_use_id: 'a' } as never)
  await w.clock.settle()
  w.finish('a')
  await expect(call).resolves.toMatchObject({ result: {} })
  expect(w.ran()).toBe(1)
  expect(w.writes()).toBeGreaterThanOrEqual(1)
})

test('a refused last state write still answers the tool, once', async ($, on) => {
  const w = world(on)
  w.refuse.from = 2
  w.refuse.count = 1
  const call = $.tool.call({ tool: 'Bash', command: 'make', tool_use_id: 'a' } as never)
  await w.clock.settle()
  w.finish('a')
  await expect(call).resolves.toMatchObject({ result: {} })
  expect(w.ran()).toBe(1)
  expect(w.writes()).toBeGreaterThanOrEqual(2)
})
