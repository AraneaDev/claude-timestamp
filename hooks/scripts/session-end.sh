#!/usr/bin/env bash
# SessionEnd hook -- user-facing.
#
# Reports what the session cost in wall-clock terms, then removes the state
# files it accumulated. The numbers come from counters that message-display.sh
# maintains per turn, so this hook only reads and formats them.
#
# "Waiting" is the sum of prompt-to-reply times, which is the part of the
# session you actually spent watching a cursor. The remainder of the elapsed
# total is your own thinking, reading, and typing.
#
# Invoked as `bash <this script>` (see hooks.json), so it does not depend on
# the executable bit surviving clones, zips, or Windows checkouts.
set -euo pipefail

command -v jq >/dev/null 2>&1 || exit 0

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/config.sh"

input="$(cat)"
IFS=$'\x1f' read -r session_id cwd <<< "$(printf '%s' "$input" \
  | jq -r '[(.session_id // ""), (.cwd // "")] | join("\u001f")')"

ct_load_config "$cwd"

# The master switch gates everything that draws on screen or talks to the
# model, but not cleanup: a session switched off mid-way still accumulated
# state files, and skipping the clear here would strand them until the 7-day
# sweep instead of at the session's own end. ct_clear_state returns 0 on a
# bad or empty session id, so this is safe either way.
if [ "$CT_ENABLED" != "on" ]; then
  ct_clear_state "$session_id"
  exit 0
fi

state_file="$(ct_state_file "$session_id")" || { ct_clear_state "$session_id"; exit 0; }

summary=""

if [ "$CT_SUMMARY" = "on" ]; then
  started="$(ct_read_counter "${state_file}.start")"
  turns="$(ct_read_counter "${state_file}.turns")"
  waited="$(ct_read_counter "${state_file}.wait")"

  # A session with no recorded turns has nothing worth reporting -- most likely
  # it was opened and closed, or the plugin was configured mid-session.
  idle="$(ct_read_counter "${state_file}.idle")"
  failed="$(ct_read_counter "${state_file}.failed")"

  if [ "$started" -gt 0 ] && [ "$turns" -gt 0 ]; then
    total=$(( $(date +%s) - started ))
    [ "$total" -lt 0 ] && total=0
    summary="claude-timestamp: session lasted $(ct_format_duration "$total") over $turns turn"
    [ "$turns" -eq 1 ] || summary="${summary}s"
    summary="${summary}, $(ct_format_duration "$waited") of it waiting"
    # Only mentioned when there was a break worth mentioning, so a session you
    # sat through end to end does not read as though it had gaps.
    [ "$idle" -gt 0 ] && summary="${summary}, $(ct_format_duration "$idle") away"
    summary="${summary}."
  fi

  # Tool timings, when they were being collected. Summed per tool and reported
  # worst-first, because the question this answers is "what made this session
  # slow", not "how long did any single call take".
  log="${state_file}.tools"
  if [ "$CT_TOOL_TIMING" = "on" ] && [ -s "$log" ]; then
    tools="$(awk '{ sum[$1] += $2; n[$1]++ }
                  END { for (t in sum) printf "%.3f\t%s\t%d\n", sum[t], t, n[t] }' "$log" \
             | sort -rn | head -3 \
             | awk -F'\t' '{
                 calls = ($3 == 1) ? "1 call" : $3 " calls"
                 printf "%s%s %.1fs (%s)", (NR > 1 ? ", " : ""), $2, $1, calls
               }')"
    if [ -n "$tools" ]; then
      [ -n "$summary" ] && summary="$summary"$'\n'
      summary="${summary}slowest tools: $tools"
      if [ "$failed" -gt 0 ]; then
        summary="${summary}. $failed failed"
      fi
    fi
  fi
fi

[ -n "$summary" ] && jq -n --arg msg "$summary" '{systemMessage: $msg}'

# Record the session before its state is cleared, so /timestamps stats has
# something to work from once the session is gone.
if [ "$CT_HISTORY" = "on" ] && [ "${started:-0}" -gt 0 ] && [ "${turns:-0}" -gt 0 ]; then
  ct_history_append "${total:-0}" "$turns" "$waited" "${idle:-0}" "${failed:-0}"
fi

ct_clear_state "$session_id"
exit 0
