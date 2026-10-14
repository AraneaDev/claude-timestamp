const pad = (n: number) => String(n).padStart(2, '0')

// Seconds -> 45s / 2m14s / 1h03m: ct_format_duration, so the live clock and
// the markers never disagree about how a duration is written.
export function formatDuration(seconds: number): string {
  const s = Number.isFinite(seconds) && seconds > 0 ? Math.floor(seconds) : 0
  if (s < 60) return `${s}s`
  if (s < 3600) return `${Math.floor(s / 60)}m${pad(s % 60)}s`
  return `${Math.floor(s / 3600)}h${pad(Math.floor((s % 3600) / 60))}m`
}
