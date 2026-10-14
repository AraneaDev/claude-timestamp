export type LiveCall = {
  /** tool_use_id, or a minted id when the call has none */
  id: string
  tool: string
  /** the command-memory key, for a foreground Bash call */
  key?: string
  /** epoch ms */
  startedAt: number
}

declare module 'claude-code' {
  interface PluginState {
    'claude-timestamp': {
      running: LiveCall[]
      /** epoch ms of the open main turn; null between turns */
      turnStartedAt: number | null
      /** the last main turn's duration, ms; null before the first */
      lastTurnMs: number | null
      /** epoch ms, the mod's own fallback when bash's .start is unreadable */
      sessionStartedAt: number | null
    }
  }
}
