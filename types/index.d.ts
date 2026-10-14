export type LiveCall = {
  /** tool_use_id, or a minted id when the call has none */
  id: string
  tool: string
  /** the command-memory key, for a foreground Bash call */
  key?: string
  /** epoch ms */
  startedAt: number
  /** the subagent or teammate loop it runs in; absent on the main loop */
  agentId?: string
  /** it went to a permission prompt, so its elapsed time includes the person's */
  isAsked?: boolean
}

declare module 'claude-code' {
  interface PluginState {
    'timestamps': {
      running: LiveCall[]
      /** epoch ms of the open main turn; null between turns */
      turnStartedAt: number | null
      /** the last main turn's duration, ms; null before the first */
      lastTurnMs: number | null
      /** epoch ms, the mod's own fallback when bash's .start is unreadable */
      sessionStartedAt: number | null
      /** the footer label the clock draws; null draws none */
      clockText: string | null
    }
  }
}
