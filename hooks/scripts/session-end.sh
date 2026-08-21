#!/usr/bin/env bash
# SessionEnd hook -- user-facing.
#
# Reports what the session cost in wall-clock terms, then removes the state
# files it accumulated. Most of what it reports comes from counters that
# user-prompt-submit.sh and stop.sh maintain per turn, but a session can end
# mid-turn, with no Stop to close it, so this hook also closes that last turn
# itself before reading anything.
#
# "Waiting" is the sum of prompt-to-reply times, which is the part of the
# session you actually spent watching a cursor. The remainder of the elapsed
# total is your own thinking, reading, and typing.
#
# Invoked as `bash <this script>` (see hooks.json), so it does not depend on
# the executable bit surviving clones, zips, or Windows checkouts.
set -euo pipefail

command -v jq >/dev/null 2>&1 || exit 0

CT_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
source "$CT_LIB/config.sh"
source "$CT_LIB/state.sh"

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

# A session can end mid-turn, which leaves a turn no Stop ever closed. That is
# the same reconciliation the next prompt would have done, at the one other
# place a turn can be abandoned, so the last turn of a session is not silently
# dropped from its own summary.
if [ "$CT_SUMMARY" = "on" ]; then
  ct_close_turn "$state_file" "$(ct_read_counter "${state_file}.last")"
fi

summary=""

if [ "$CT_SUMMARY" = "on" ]; then
  started="$(ct_read_counter "${state_file}.start")"
  turns="$(ct_read_counter "${state_file}.turns")"
  waited="$(ct_read_counter "${state_file}.wait")"

  # A session with no recorded turns has nothing worth reporting -- most likely
  # it was opened and closed, or the plugin was configured mid-session.
  idle="$(ct_read_counter "${state_file}.idle")"

  # Failures are counted out of the tool log rather than from a counter, so
  # concurrent tool calls appending at once are all seen. A log that is absent
  # or was never written means no failures to report.
  log="${state_file}.tools"
  failed=0
  [ -s "$log" ] && failed="$(awk '$3 == "fail" { n++ } END { print n + 0 }' "$log")"

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
