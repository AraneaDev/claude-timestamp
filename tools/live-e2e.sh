#!/usr/bin/env bash
# End-to-end check of the live layer in a real terminal session: starts
# `claude --plugin-dir .` in a detached tmux pane, has it run one slow Bash
# command, and reads the screen while it runs. Makes real model calls, so it
# is run by hand, never in CI.
#
#   tools/live-e2e.sh [seconds]     how long the command runs (default 25)
#
# Command history, turn history and config are throwaway files. The command
# history holds three 8s runs of `timeout`, so the line under the call should appear after ~12s (1.5 x the usual time)
# and say "usually ~8s". The person's own files are never written.
set -u

secs="${1:-25}"
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/ct-live-e2e.XXXXXX")"
pane="ct-live-e2e-$$"
project="$(basename "$root")"
cmd="timeout $secs tail -f /dev/null; echo \"exit: \$?\""

now=$(date +%s)
for i in 1 2 3; do
  printf '%s\t%s\ttimeout\t8000\tok\n' "$((now - 100 + i))" "$project"
done > "$work/commands.tsv"
# The person's settings, with the slow-tool note at 20s so bash's own note
# fires too, and LIVE on.
{ cat "$HOME/.claude/claude-timestamp.conf" 2>/dev/null; printf 'SLOW_TOOL_AFTER=20\nLIVE=on\n'; } > "$work/timestamp.conf"
printf '{"permissions":{"allow":["Bash(timeout %s tail -f /dev/null)","Bash(echo:*)"]}}\n' "$secs" > "$work/settings.json"

cleanup() { tmux kill-session -t "$pane" 2>/dev/null; }
trap cleanup EXIT

tmux new-session -d -s "$pane" -x 160 -y 50 -c "$root" \
  "CLAUDE_TIMESTAMP_COMMANDS='$work/commands.tsv' CLAUDE_TIMESTAMP_CONFIG='$work/timestamp.conf' \
   CLAUDE_TIMESTAMP_HISTORY='$work/history.tsv' claude --plugin-dir '$root' \
   --settings '$work/settings.json' --debug-file '$work/debug.txt'"

shot() { tmux capture-pane -p -t "$pane" > "$work/$1.txt" 2>/dev/null; }

# Ready when the prompt box is drawn.
for _ in $(seq 60); do
  shot boot
  grep -q '❯' "$work/boot.txt" && break
  sleep 1
done

tmux send-keys -t "$pane" -l "Run this exact Bash command in the foreground, once, with no other tool calls, then reply only 'done': $cmd"
sleep 1
tmux send-keys -t "$pane" Enter

# One snapshot a second until the reply, or the command's time plus a minute.
started=$(date +%s)
n=0
while [ $(( $(date +%s) - started )) -lt $((secs + 60)) ]; do
  n=$((n + 1))
  shot "t$(printf '%03d' "$n")"
  # The reply, after the plugin's own marker: "● [17:19:31 +34s] done".
  if grep -qE '^[●⏺] (\[[^]]*\] )?done$' "$work/t$(printf '%03d' "$n").txt"; then
    sleep 2
    shot final
    break
  fi
  sleep 1
done
[ -f "$work/final.txt" ] || shot final

pass=0 fail=0
check() {
  if grep -qE "$2" "$work"/t*.txt "$work/final.txt" 2>/dev/null; then
    echo "  ok   $1"; pass=$((pass + 1))
  else
    echo "  FAIL $1  (no screen matched: $2)"; fail=$((fail + 1))
  fi
}
echo "live layer, end to end ($secs s command; screens in $work)"
check "footer clock ticks during the turn" '⏱ [0-9]+s'
check "the line under the call: elapsed and usual time" '\([0-9]+s · usually ~8s'
check "the key is timeout, not the trailing echo" 'usually ~8s'
# Bash's note goes to the model, not the screen: the debug log carries it.
if grep -qE "That Bash call took [0-9]+s \(usually 8s\)" "$work/debug.txt" 2>/dev/null; then
  echo "  ok   bash's note quotes the same usual time"; pass=$((pass + 1))
else
  echo "  FAIL bash's note quotes the same usual time"; fail=$((fail + 1))
fi
if tail -1 "$work/commands.tsv" | grep -qP "\ttimeout\t[0-9]+\tok$"; then
  echo "  ok   the run is remembered under timeout"; pass=$((pass + 1))
else
  echo "  FAIL the run is remembered under timeout ($(tail -1 "$work/commands.tsv"))"; fail=$((fail + 1))
fi
if grep -q '⚠' "$work"/t*.txt; then
  echo "  FAIL no ⚠ notice is drawn"; fail=$((fail + 1))
else
  echo "  ok   no ⚠ notice is drawn"; pass=$((pass + 1))
fi
grep -h 'claude-timestamp' "$work/debug.txt" 2>/dev/null | grep -iE 'refused|error|fail' | head -5
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
