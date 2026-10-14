// The live layer's hooks: a ticking clock in the status line, and a band
// above the prompt while a tool runs slow. Display only: bash measures and
// records. What a drawing reads is in $.state, so a hot reload keeps it.
import { atom, read, update } from 'claude-code'
import type { EngineInterface, On, Timer } from 'claude-code'
import type { LiveCall } from '../../types'
import { readBashState } from './bash-state.ts'
import type { Host } from './bash-state.ts'
import { formatDuration } from './format.ts'

export const running = atom({ plugin: 'claude-timestamp', key: 'running' } as const, [] as LiveCall[])
export const turnStartedAt = atom({ plugin: 'claude-timestamp', key: 'turnStartedAt' } as const, null as number | null)
export const lastTurnMs = atom({ plugin: 'claude-timestamp', key: 'lastTurnMs' } as const, null as number | null)
export const sessionStartedAt = atom(
  { plugin: 'claude-timestamp', key: 'sessionStartedAt' } as const,
  null as number | null,
)

const TICK_MS = 1000

function hostOf($: EngineInterface): Host {
  return {
    // $.env.get takes a literal name, so the variables a module reads can be
    // listed: one call per name.
    env: name => {
      switch (name) {
        case 'TMPDIR':
          return $.env.get('TMPDIR')
        case 'UID':
          return $.env.get('UID')
        case 'HOME':
          return $.env.get('HOME')
        case 'CLAUDE_TIMESTAMP_COMMANDS':
          return $.env.get('CLAUDE_TIMESTAMP_COMMANDS')
      }
    },
    sessionId: () => $.session.id(),
    read: path => $.fs.read(path),
    run: argv => $.process.run(argv),
  }
}
let ticker: Timer | undefined

async function paint($: EngineInterface): Promise<void> {
  const bash = await readBashState(hostOf($))
  if (!bash.isOn) {
    $.ui.status(undefined)
    return
  }
  const now = await $.clock.now()
  const started = await read($, turnStartedAt)
  const turnMs = started !== null ? now - started : await read($, lastTurnMs)
  if (turnMs === null) {
    $.ui.status(undefined)
    return
  }
  const sessionStart = bash.sessionStartedAt ?? (await read($, sessionStartedAt))
  const session = sessionStart === null ? '' : ` · session ${formatDuration((now - sessionStart) / 1000)}`
  $.ui.status(`⏱ ${formatDuration(turnMs / 1000)}${session}`)
}

function startTicking($: EngineInterface): void {
  ticker?.cancel()
  ticker = $.clock.every(TICK_MS, () => {
    paint($).catch(() => undefined)
  })
}

function stopTicking(): void {
  ticker?.cancel()
  ticker = undefined
}

export function registerLive(on: On): void {
  on('session.start', async ($, e, next) => {
    const now = await $.clock.now()
    await update($, sessionStartedAt, v => v ?? now)
    // A reload mid-turn: the turn is still open in $.state; tick again.
    if ((await read($, turnStartedAt)) !== null) startTicking($)
    return next(e)
  })

  on('turn.start', async ($, e, next) => {
    const now = await $.clock.now()
    // A subagent's turn inside the main one keeps the main turn's start.
    await update($, turnStartedAt, v => v ?? now)
    startTicking($)
    await paint($)
    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    if (e.agentId === undefined) {
      stopTicking()
      await update($, turnStartedAt, () => null)
      await update($, lastTurnMs, () => e.durationMs)
      await paint($)
    }
    return next(e)
  })
}
