// The live layer's hooks: a ticking clock in the status line, and a band
// above the prompt while a tool runs slow. Display only: bash measures and
// records. What a drawing reads is in $.state, so a hot reload keeps it.
import { atom, read, update } from 'claude-code'
import type { EngineInterface, On, Timer } from 'claude-code'
import type { LiveCall } from '../../types'
import { readBashState, readCommandsFile } from './bash-state.ts'
import type { Host } from './bash-state.ts'
import { cmdKey } from './cmdkey.ts'
import { formatDuration } from './format.ts'
import { usualSeconds } from './usual.ts'

export const running = atom({ plugin: 'claude-timestamp', key: 'running' } as const, [] as LiveCall[])
export const turnStartedAt = atom({ plugin: 'claude-timestamp', key: 'turnStartedAt' } as const, null as number | null)
export const lastTurnMs = atom({ plugin: 'claude-timestamp', key: 'lastTurnMs' } as const, null as number | null)
export const sessionStartedAt = atom(
  { plugin: 'claude-timestamp', key: 'sessionStartedAt' } as const,
  null as number | null,
)

const TICK_MS = 1000
const MIN_BAND_S = 10
const USUAL_FACTOR = 1.5

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

let redraw: Timer | undefined
let minted = 0
// Looked up once per call, when it has run MIN_BAND_S; lost on reload, then
// looked up again. null means "looked, nothing usual".
const usualById = new Map<string, number | null>()

// The band's elapsed time moves with the clock, not with state, so while
// anything runs it is redrawn each second.
function syncRedraw($: EngineInterface, isRunning: boolean): void {
  if (isRunning && !redraw) {
    redraw = $.clock.every(TICK_MS, () => $.ui.invalidate('ui.render'))
  } else if (!isRunning && redraw) {
    redraw.cancel()
    redraw = undefined
  }
}

async function usualFor($: EngineInterface, call: LiveCall, project: string | undefined): Promise<number | undefined> {
  if (!call.key) return undefined
  if (!usualById.has(call.id)) {
    usualById.set(call.id, usualSeconds(await readCommandsFile(hostOf($)), project, call.key) ?? null)
  }
  return usualById.get(call.id) ?? undefined
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
  on('tool.call', async ($, e, next) => {
    const input = e as { run_in_background?: unknown; command?: unknown }
    // A background call's duration is only its start-up: never slow.
    if (e.tool === 'Bash' && input.run_in_background === true) return next(e)
    const id = e.tool_use_id ?? `live-${++minted}`
    const key = e.tool === 'Bash' ? cmdKey(input.command) || undefined : undefined
    const startedAt = await $.clock.now()
    await update($, running, list => [...list, { id, tool: String(e.tool), key, startedAt }])
    syncRedraw($, true)
    try {
      return await next(e)
    } finally {
      const left = await update($, running, list => list.filter(c => c.id !== id))
      usualById.delete(id)
      syncRedraw($, left.length > 0)
    }
  }).catch(($, e, next) => next(e))

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (e.props.hasSurvey) return next(e)
    const calls = await read($, running)
    if (calls.length === 0) return next(e)
    const bash = await readBashState(hostOf($))
    if (!bash.isOn) return next(e)
    const now = await $.clock.now()
    const slow: Array<{ call: LiveCall; elapsed: number; usual?: number }> = []
    for (const call of calls) {
      const elapsed = (now - call.startedAt) / 1000
      if (elapsed < MIN_BAND_S) continue
      const usual = bash.isCommandMemoryOn ? await usualFor($, call, bash.project) : undefined
      const isPastUsual = usual !== undefined && elapsed > Math.max(USUAL_FACTOR * usual, MIN_BAND_S)
      const isPastSlow = bash.slowToolAfter > 0 && elapsed > bash.slowToolAfter
      if (isPastUsual || isPastSlow) slow.push({ call, elapsed, usual })
    }
    const top = slow.sort((a, b) => b.elapsed - a.elapsed)[0]
    if (top === undefined) return next(e)
    const parts = [top.call.key ?? top.call.tool, formatDuration(top.elapsed)]
    if (top.usual !== undefined) parts.push(`usually ~${formatDuration(top.usual)}`)
    if (calls.length > 1) parts.push(`+${calls.length - 1} more`)
    const { Text } = $.ui.resolve(e)
    return <Text dimColor>{parts.join(' · ')}</Text>
  }).catch(($, e, next) => next(e))
}
