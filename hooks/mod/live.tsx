// The live layer's hooks: a ticking clock in the status line, and a band
// above the prompt while a tool runs slow. Display only: bash measures and
// records. What a drawing reads is in $.state, so a hot reload keeps it.
import { atom, read, update } from 'claude-code'
import type { EngineInterface, On, Timer } from 'claude-code'
import type { LiveCall } from '../../types'
import { readBashState, readCommandsFile } from './bash-state.ts'
import type { BashState, Host } from './bash-state.ts'
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
// Their whole duration is the person's own time: a question, a plan to approve.
const INTERACTIVE = new Set(['AskUserQuestion', 'ExitPlanMode'])

// The uid, asked once per module load: $UID is a shell variable bash does not
// export, so the hooks environment lacks it and id -u is a process start.
let uid: Promise<string | undefined> | undefined

async function lookUpUid($: EngineInterface): Promise<string | undefined> {
  const fromEnv = await $.env.get('UID')
  if (fromEnv) return fromEnv
  try {
    const ran = await $.process.run(['id', '-u'])
    return ran.exitCode === 0 ? ran.stdout.trim() : undefined
  } catch {
    return undefined
  }
}

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
    uid: () => (uid ??= lookUpUid($)),
  }
}

let ticker: Timer | undefined
// What bash staged, read once when the turn starts (its prompt hook has run
// by then) rather than on every tick.
let turnBash: BashState | undefined

async function bashState($: EngineInterface): Promise<BashState> {
  if (turnBash?.isOn && turnBash.sessionStartedAt !== undefined) return turnBash
  return (turnBash = await readBashState(hostOf($)))
}

async function paint($: EngineInterface): Promise<void> {
  const bash = turnBash ?? (await bashState($))
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
    // A reload mid-turn: the turn and its calls are still in $.state, while
    // this environment's timers are new. Start them again.
    if ((await read($, turnStartedAt)) !== null) startTicking($)
    syncRedraw($, (await read($, running)).length > 0)
    return next(e)
  })

  on('turn.start', async ($, e, next) => {
    const now = await $.clock.now()
    // Only the main loop raises turn.start (a subagent's run raises none), so
    // each one is a new turn, even if the last one's completion was missed.
    await update($, turnStartedAt, () => now)
    turnBash = await readBashState(hostOf($))
    if (turnBash.isOn) {
      startTicking($)
      await paint($)
    } else {
      stopTicking()
      $.ui.status(undefined)
    }
    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    if (e.agentId === undefined) {
      stopTicking()
      await update($, turnStartedAt, () => null)
      await update($, lastTurnMs, () => e.durationMs)
      // The main loop's calls are over when its turn is; one still listed was
      // left behind by a hook that never finished.
      const left = await update($, running, list => list.filter(c => c.agentId !== undefined))
      syncRedraw($, left.length > 0)
      await paint($)
    }
    return next(e)
  }).catch(($, e, next) => next(e))

  on('tool.call', async ($, e, next) => {
    const input = e as { run_in_background?: unknown; command?: unknown }
    // A background call's duration is only its start-up, and an interactive
    // one's is the person's: neither is ever slow.
    if (e.tool === 'Bash' && input.run_in_background === true) return next(e)
    if (INTERACTIVE.has(String(e.tool))) return next(e)
    const id = e.tool_use_id ?? `live-${++minted}`
    const key = e.tool === 'Bash' ? cmdKey(input.command) || undefined : undefined
    const startedAt = await $.clock.now()
    const call: LiveCall = { id, tool: String(e.tool), key, startedAt, agentId: e.agentId }
    await update($, running, list => [...list, call])
    syncRedraw($, true)
    try {
      return await next(e)
    } finally {
      const left = await update($, running, list => list.filter(c => c.id !== id))
      usualById.delete(id)
      syncRedraw($, left.length > 0)
    }
  }).catch(($, e, next) => next(e))

  // A call that goes to a permission prompt has the person's time in its
  // elapsed time, and no event says when they answered: the band leaves it out.
  on('tool.check', async ($, e, next) => {
    const verdict = await next(e)
    const id = e.tool_use_id
    if (verdict.decision === 'ask' && id !== undefined) {
      await update($, running, list => list.map(c => (c.id === id ? { ...c, isAsked: true } : c)))
    }
    return verdict
  }).catch(($, e, next) => next(e))

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (e.props.hasSurvey) return next(e)
    const calls = await read($, running)
    const now = await $.clock.now()
    const candidates = calls.filter(c => !c.isAsked && now - c.startedAt >= MIN_BAND_S * 1000)
    // Most redraws are of short calls: answer them before reading any file.
    if (candidates.length === 0) return next(e)
    const bash = await bashState($)
    if (!bash.isOn) return next(e)
    const slow: Array<{ call: LiveCall; elapsed: number; usual?: number }> = []
    for (const call of candidates) {
      const elapsed = (now - call.startedAt) / 1000
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
