// A port of ct_command_usual over ct_command_stats (hooks/scripts/lib/state.sh):
// how long a command usually takes in a project, from bash's command memory.
// usual.cases.ts holds both to the same answers.

const WINDOW = 20
const MIN_RUNS = 3

export function usualSeconds(tsv: string, project: string | undefined, key: string): number | undefined {
  if (!key || !project || project === '-') return undefined
  const runs: number[] = []
  for (const line of tsv.split('\n')) {
    const f = line.split('\t')
    if (f.length !== 5) continue
    const [epoch = '', where, name, ms = '', outcome] = f
    if (!/^[0-9]+$/.test(epoch) || !/^[0-9]+$/.test(ms)) continue
    if (outcome !== 'ok' && outcome !== 'fail') continue
    if (where !== project || name !== key) continue
    runs.push(Number(ms))
  }
  if (runs.length < MIN_RUNS) return undefined
  const a = runs.slice(-WINDOW).sort((x, y) => x - y)
  const m = a.length
  const at = (i: number) => a[i] ?? 0
  const med = m % 2 ? at((m - 1) / 2) : Math.floor((at(m / 2 - 1) + at(m / 2)) / 2)
  return Math.floor(med / 1000)
}
