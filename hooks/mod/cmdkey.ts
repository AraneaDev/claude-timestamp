// A port of ct_cmdkey (CT_JQ_CMDKEY, hooks/scripts/lib/state.sh). The same
// short key bash files a Bash call's duration under, so the band can look up
// the usual time. cmdkey.cases.ts holds both to the same answers; change one
// and the other's tests fail.

const PLAIN = /^[0-9A-Za-z._\/@:+-]+$/
const PREFIXES = new Set(['env', 'time', 'sudo', 'nice', 'command'])

const len = (s: string) => [...s].length
const words = (s: string) => s.split(' ').filter(w => w.length > 0)
const isPlain = (s: string) => PLAIN.test(s)
const isDigits = (s: string) => /^[0-9]*$/.test(s)

// Quoted text and $(...) / ${...} bodies vanish; quotes and brackets become
// spaces, so nothing inside them can split a command or reach the key.
function unquote(s: string): string {
  let q: string | null = null
  let p = ''
  let out = ''
  for (const c of s) {
    let e: string | null
    if (q !== null) {
      if (c === q) q = null
      e = null
    } else if (p === '$' && c === '(') {
      q = ')'
      e = null
    } else if (p === '$' && c === '{') {
      q = '}'
      e = null
    } else if (c === '"' || c === "'") {
      q = c
      e = ' '
    } else if (c === '(' || c === ')' || c === '{' || c === '}') {
      e = ' '
    } else {
      e = c
    }
    p = c
    if (e !== null) out += e
  }
  return out
}

function stops(w: string): boolean {
  return (
    w.startsWith('-') ||
    w.includes('://') ||
    w.includes('..') ||
    w.startsWith('/') ||
    w.startsWith('~') ||
    isDigits(w) ||
    !isPlain(w) ||
    (w.includes('@') && !w.startsWith('@')) ||
    w.includes(':/') ||
    (len(w) >= 16 && !w.includes('/') && /[A-Za-z]/.test(w) && /[0-9]/.test(w))
  )
}

const isPrefix = (w: string) => w.includes('=') || PREFIXES.has(w)

export function cmdKey(command: unknown): string {
  if (typeof command !== 'string') return ''
  const line = unquote(command.split('\n')[0] ?? '').split('\t').join(' ')
  const segments = ['&&', '||', ';']
    .reduce<string[]>((parts, sep) => parts.flatMap(p => p.split(sep)), [line])
    .filter(seg => words(seg).length > 0)
  const segment = segments[segments.length - 1] ?? ''
  let ws = words(segment.split('|')[0] ?? '').slice(0, 40)
  while (ws.length > 0 && isPrefix(ws[0])) ws = ws.slice(1)
  if (ws.length === 0) return ''
  const parts = ws[0].split('/')
  const prog = parts[parts.length - 1]
  if (!isPlain(prog) || prog.startsWith('-')) return ''
  if (prog === 'echo' || prog === 'printf') return prog
  const kept: string[] = []
  for (const w of ws.slice(1, 3)) {
    if (stops(w)) break
    kept.push(w)
  }
  return [...[prog, ...kept].join(' ')].slice(0, 60).join('')
}
