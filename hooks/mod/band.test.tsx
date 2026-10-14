import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

const DIR = '/tmp/claude-timestamp-1000'
const SURFACES = ['terminal', 'desktop'] as const
const BAND = {
  component: 'AbovePrompt' as const,
  props: { hasSurvey: false, isWorking: true, maxRows: 10, bodyColumns: 80, scroll: { offset: 0, bodyRows: 10 } },
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
  on('fs.read', ($, e) => (e.path in files ? { value: files[e.path] } : { deny: `ENOENT ${e.path}` }))
  on('ui.status', () => ({ value: undefined }))
  on('ui.invalidate', () => ({ value: undefined }))
  // The engine's own band, beneath the plugin: drawn when the plugin passes.
  on('ui.render', { component: 'AbovePrompt' }, ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>engine band</Text>
  })
  // Each tool runs until the test finishes it.
  const finish: Record<string, () => void> = {}
  const fail: Record<string, () => void> = {}
  on('tool.call', async ($, e) => {
    await new Promise<void>((resolve, reject) => {
      finish[e.tool_use_id ?? ''] = resolve
      fail[e.tool_use_id ?? ''] = () => reject(new Error('boom'))
    })
    return { result: {} } as never
  })
  return { clock, finish, fail }
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
  finish.a()
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
  finish.a()
  await call
})

test('several running: the longest slow one, plus a count', async ($, on) => {
  const { clock, finish } = world(on)
  const one = $.tool.call({ tool: 'Bash', command: 'make', tool_use_id: 'a' } as never)
  await clock.advance(10_000)
  const two = $.tool.call({ tool: 'Read', file_path: '/x', tool_use_id: 'b' } as never)
  await clock.advance(55_000)
  expect(await bandText($, 'terminal')).toBe('make · 1m05s · +1 more')
  finish.a()
  await one
  expect(await bandText($, 'terminal')).toBeUndefined()
  finish.b()
  await two
})

test('a background command never shows', async ($, on) => {
  const { clock, finish } = world(on)
  const call = $.tool.call({ tool: 'Bash', command: 'npm test', run_in_background: true, tool_use_id: 'a' } as never)
  await clock.advance(120_000)
  expect(await bandText($, 'terminal')).toBeUndefined()
  finish.a()
  await call
})

test('a tool that errors beneath still leaves the band', async ($, on) => {
  const { clock, fail } = world(on)
  const call = $.tool.call({ tool: 'Bash', command: 'make', tool_use_id: 'a' } as never).catch(() => undefined)
  await clock.advance(70_000)
  expect(await bandText($, 'terminal')).toBe('make · 1m10s')
  fail.a()
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
  finish.a()
  await expect(call).resolves.toBeDefined()
})
