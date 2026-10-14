// The live layer: Claude Code only, display only. Bash measures and records
// everything; this module reads what bash staged and draws it while it is
// still happening. Codex and builds without modules ignore this file.
import type { Register } from 'claude-code'
import { registerLive } from './live.tsx'

export const register: Register = on => {
  registerLive(on)
}
