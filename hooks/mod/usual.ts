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
    if (!/^[0-9]+$/.test(f[0]) || !/^[0-9]+$/.test(f[3])) continue
    if (f[4] !== 'ok' && f[4] !== 'fail') continue
    if (f[1] !== project || f[2] !== key) continue
    runs.push(Number(f[3]))
  }
  if (runs.length < MIN_RUNS) return undefined
  const a = runs.slice(-WINDOW).sort((x, y) => x - y)
  const m = a.length
  const med = m % 2 ? a[(m - 1) / 2] : Math.floor((a[m / 2 - 1] + a[m / 2]) / 2)
  return Math.floor(med / 1000)
}
