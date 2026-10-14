// The live layer's hooks: a ticking clock among the footer's labels, and a
// slow tool's time under its call (Bash, terminal) or above the prompt. Display only: bash measures and
// records. What a drawing reads is in $.state, so a hot reload keeps it.
import { atom, read, update } from 'claude-code'
import type { EngineInterface, On, Timer } from 'claude-code'
import type { LiveCall } from '../../types'
import { readBashState, readCommandsFile } from './bash-state.ts'
import type { BashState, Host } from './bash-state.ts'
import { cmdKey } from './cmdkey.ts'
import { formatDuration } from './format.ts'
import { usualSeconds } from './usual.ts'

export const running = atom({ plugin: 'timestamps', key: 'running' } as const, [] as LiveCall[])
export const turnStartedAt = atom({ plugin: 'timestamps', key: 'turnStartedAt' } as const, null as number | null)
export const lastTurnMs = atom({ plugin: 'timestamps', key: 'lastTurnMs' } as const, null as number | null)
// What the footer label says; null draws none.
export const clockText = atom({ plugin: 'timestamps', key: 'clockText' } as const, null as string | null)
export const sessionStartedAt = atom(
  { plugin: 'timestamps', key: 'sessionStartedAt' } as const,
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

// isCurrent is asked right before the label is written: a tick still
// drawing when its turn ends must not replace the figure the turn's
// completion wrote.
async function paint($: EngineInterface, isCurrent: () => boolean = () => true): Promise<void> {
  const bash = turnBash ?? (await bashState($))
  if (!bash.isOn) {
    if (isCurrent()) await update($, clockText, () => null)
    return
  }
  const now = await $.clock.now()
  const started = await read($, turnStartedAt)
  // A running turn counts whole seconds up; a finished one is rounded, as the
  // engine's own "Worked for" line rounds it.
  const held = started === null ? await read($, lastTurnMs) : null
  const turnMs = started !== null ? now - started : held === null ? null : Math.round(held / 1000) * 1000
  if (turnMs === null) {
    if (isCurrent()) await update($, clockText, () => null)
    return
  }
  const sessionStart = bash.sessionStartedAt ?? (await read($, sessionStartedAt))
  const session = sessionStart === null ? '' : ` · session ${formatDuration((now - sessionStart) / 1000)}`
  const text = `⏱ ${formatDuration(turnMs / 1000)}${session}`
  if (isCurrent()) await update($, clockText, () => text)
}

function startTicking($: EngineInterface): void {
  ticker?.cancel()
  const mine: Timer = $.clock.every(TICK_MS, () => {
    paint($, () => ticker === mine).catch(() => undefined)
  })
  ticker = mine
}

function stopTicking(): void {
  ticker?.cancel()
  ticker = undefined
}

let redraw: Timer | undefined
// Looked up once per call, when it has run MIN_BAND_S; lost on reload, then
// looked up again. null means "looked, nothing usual".
const usualByCall = new Map<string, number | null>()
const cacheKey = (call: LiveCall) => `${call.id}@${call.startedAt}`

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
  const k = cacheKey(call)
  if (!usualByCall.has(k)) {
    usualByCall.set(k, usualSeconds(await readCommandsFile(hostOf($)), project, call.key) ?? null)
  }
  return usualByCall.get(k) ?? undefined
}

type Slow = { call: LiveCall; elapsed: number; usual?: number }

// The calls among these that are slow, longest first. Most redraws are of
// short calls, so they are answered before any file is read.
async function slowCalls($: EngineInterface, calls: readonly LiveCall[]): Promise<Slow[]> {
  const now = await $.clock.now()
  const candidates = calls.filter(c => !c.isAsked && now - c.startedAt >= MIN_BAND_S * 1000)
  if (candidates.length === 0) return []
  const bash = await bashState($)
  if (!bash.isOn) return []
  const slow: Slow[] = []
  for (const call of candidates) {
    const elapsed = (now - call.startedAt) / 1000
    const usual = bash.isCommandMemoryOn ? await usualFor($, call, bash.project) : undefined
    // A known usual time is the better measure, so it alone decides; the
    // slow-tool threshold is for calls with no history, in whole seconds as
    // bash's own note counts them.
    const isSlow =
      usual !== undefined
        ? elapsed > Math.max(USUAL_FACTOR * usual, MIN_BAND_S)
        : bash.slowToolAfter > 0 && Math.floor(elapsed) >= bash.slowToolAfter
    if (isSlow) slow.push({ call, elapsed, usual })
  }
  return slow.sort((a, b) => b.elapsed - a.elapsed)
}

// `1m10s`, and `usually ~40s` when the command has a usual time.
function describe(slow: Slow): string[] {
  const parts = [formatDuration(slow.elapsed)]
  // A median under a second floors to 0, which is no duration to quote.
  if (slow.usual === 0) parts.push('usually under 1s')
  else if (slow.usual !== undefined) parts.push(`usually ~${formatDuration(slow.usual)}`)
  return parts
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

  // A /clear ends the conversation without a new session.start: the session
  // total starts again from here until bash stages the new conversation's.
  on('session.end', async ($, e, next) => {
    if (e.reason === 'clear') {
      const now = await $.clock.now()
      await update($, sessionStartedAt, () => now)
      turnBash = undefined
    }
    return next(e)
  }).catch(($, e, next) => next(e))

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
      await update($, clockText, () => null)
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
      for (const k of [...usualByCall.keys()]) if (!left.some(c => cacheKey(c) === k)) usualByCall.delete(k)
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
    // The id is what removes the call again: without one it is not tracked.
    const id = e.tool_use_id
    if (id === undefined) return next(e)
    const key = e.tool === 'Bash' ? cmdKey(input.command) || undefined : undefined
    const startedAt = await $.clock.now()
    const call: LiveCall = { id, tool: String(e.tool), key, startedAt, agentId: e.agentId }
    await update($, running, list => [...list, call])
    syncRedraw($, true)
    try {
      return await next(e)
    } finally {
      const left = await update($, running, list => list.filter(c => c.id !== id))
      usualByCall.delete(cacheKey(call))
      syncRedraw($, left.length > 0)
    }
  }).catch(($, e, next) => next(e))

  // A call that waited on a permission dialog has the person's time in its
  // elapsed time, and no event says when they answered: the live layer leaves
  // it out. The dialog's hook names no call, so the newest unasked one of that
  // tool is the one. The auto-mode classifier raises no dialog, so its
  // approvals stay in.
  on('classic.PermissionRequest', async ($, e, next) => {
    const tool = e.tool_name
    await update($, running, list => {
      const at = list.findLastIndex(c => c.tool === tool && !c.isAsked)
      return at < 0 ? list : list.map((c, i) => (i === at ? { ...c, isAsked: true } : c))
    })
    return next(e)
  }).catch(($, e, next) => next(e))

  // The footer's dim labels, where the clock sits beside the engine's modes.
  on('ui.render', { component: 'SessionMode' }, async ($, e, next) => {
    const text = await read($, clockText)
    if (text === null) return next(e)
    return next({ ...e, props: { ...e.props, modes: [...e.props.modes, text] } })
  }).catch(($, e, next) => next(e))

  // The pill under a running Bash call: its own time, where the person looks.
  on('ui.render', { component: 'ToolProgress' }, async ($, e, next) => {
    const calls = await read($, running)
    const call = calls.find(c => c.id === e.props.tool_use_id)
    if (call === undefined) return next(e)
    const found = await slowCalls($, [call])
    const mine = found[0]
    if (mine === undefined) return next(e)
    const hint = e.props.hint
    const inner = hint.startsWith('(') && hint.endsWith(')') ? hint.slice(1, -1) : hint
    return next({ ...e, props: { ...e.props, hint: `(${describe(mine).join(' · ')} · ${inner})` } })
  }).catch(($, e, next) => next(e))

  // Everything else that runs slow: other tools, and Bash where no pill is
  // drawn (the terminal draws one, the desktop does not).
  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (e.props.hasSurvey) return next(e)
    const calls = await read($, running)
    const shown = e.surface === 'terminal' ? calls.filter(c => c.tool !== 'Bash') : calls
    const slow = await slowCalls($, shown)
    const top = slow[0]
    if (top === undefined) return next(e)
    const parts = [top.call.key ?? top.call.tool, ...describe(top)]
    if (slow.length > 1) parts.push(`+${slow.length - 1} more`)
    const { Text } = $.ui.resolve(e)
    return <Text dimColor>{parts.join(' · ')}</Text>
  }).catch(($, e, next) => next(e))
}
