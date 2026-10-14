// The live layer: Claude Code only, display only. Bash measures and records
// everything; this module reads what bash staged and draws it while it is
// still happening. Codex and builds without modules ignore this file.
import type { Register } from 'claude-code'

export const register: Register = on => {
  on('session.start', ($, e, next) => next(e))
}
