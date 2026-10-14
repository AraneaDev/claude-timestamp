import { expect, test } from 'claude-code/testing'
import { readBashState, readCommandsFile } from './bash-state.ts'
import type { Host } from './bash-state.ts'

const DIR = '/tmp/x/claude-timestamp-1000'

function host(files: Record<string, string>, env: Record<string, string> = { UID: '1000' }, idU = '1000\n'): Host {
  const vars: Record<string, string> = { TMPDIR: '/tmp/x/', HOME: '/home/u', ...env }
  return {
    env: async name => vars[name],
    sessionId: async () => 'ab.c/../d-1',
    read: async path => {
      const text = files[path]
      if (text === undefined) throw new Error(`ENOENT ${path}`)
      return text
    },
    run: async () => ({ exitCode: 0, stdout: idU }),
  }
}

test('reads every staged flag', async () => {
  const h = host({
    [`${DIR}/abcd-1.enabled`]: 'on',
    [`${DIR}/abcd-1.live`]: 'on',
    [`${DIR}/abcd-1.start`]: '1700000000',
    [`${DIR}/abcd-1.livetool`]: '30',
    [`${DIR}/abcd-1.project`]: 'app',
    [`${DIR}/abcd-1.cmdmem`]: 'on',
  })
  expect(await readBashState(h)).toEqual({
    isOn: true,
    sessionStartedAt: 1700000000000,
    slowToolAfter: 30,
    project: 'app',
    isCommandMemoryOn: true,
  })
})

test('the uid comes from id -u when UID is unset', async () => {
  expect((await readBashState(host({ [`${DIR}/abcd-1.enabled`]: 'on' }, {}))).isOn).toBe(true)
})

test('no uid at all is off', async () => {
  expect((await readBashState(host({ [`${DIR}/abcd-1.enabled`]: 'on' }, {}, 'nope'))).isOn).toBe(false)
})

test('nothing staged yet: off, defaults, no throw', async () => {
  expect(await readBashState(host({}))).toEqual({
    isOn: false,
    sessionStartedAt: undefined,
    slowToolAfter: 60,
    project: undefined,
    isCommandMemoryOn: false,
  })
})

test('a missing .live counts as on', async () => {
  expect((await readBashState(host({ [`${DIR}/abcd-1.enabled`]: 'on' }))).isOn).toBe(true)
})

test('LIVE=off is off', async () => {
  expect((await readBashState(host({ [`${DIR}/abcd-1.enabled`]: 'on', [`${DIR}/abcd-1.live`]: 'off' }))).isOn).toBe(false)
})

test('garbled values fall back', async () => {
  const s = await readBashState(
    host({
      [`${DIR}/abcd-1.enabled`]: 'on',
      [`${DIR}/abcd-1.start`]: '17x',
      [`${DIR}/abcd-1.livetool`]: '-3',
      [`${DIR}/abcd-1.project`]: '-',
    }),
  )
  expect([s.sessionStartedAt, s.slowToolAfter, s.project]).toEqual([undefined, 60, undefined])
})

test('a host that throws everywhere is off, not a throw', async () => {
  const boom = async () => {
    throw new Error('boom')
  }
  expect((await readBashState({ env: boom, sessionId: boom, read: boom, run: boom })).isOn).toBe(false)
})

test('the commands file honours CLAUDE_TIMESTAMP_COMMANDS', async () => {
  expect(await readCommandsFile(host({ '/c.tsv': 'row' }, { CLAUDE_TIMESTAMP_COMMANDS: '/c.tsv' }))).toBe('row')
})

test('the commands file defaults beside the config', async () => {
  expect(await readCommandsFile(host({ '/home/u/.claude/claude-timestamp-commands.tsv': 'row' }))).toBe('row')
})

test('an unreadable commands file reads empty', async () => {
  expect(await readCommandsFile(host({}))).toBe('')
})
