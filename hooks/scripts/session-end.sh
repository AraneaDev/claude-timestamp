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
ct_load_config

input="$(cat)"
session_id="$(printf '%s' "$input" | jq -r '.session_id // empty')"

state_file="$(ct_state_file "$session_id")" || exit 0

if [ "$CT_SUMMARY" = "on" ]; then
  started="$(ct_read_counter "${state_file}.start")"
  turns="$(ct_read_counter "${state_file}.turns")"
  waited="$(ct_read_counter "${state_file}.wait")"

  # A session with no recorded turns has nothing worth reporting -- most likely
  # it was opened and closed, or the plugin was configured mid-session.
  if [ "$started" -gt 0 ] && [ "$turns" -gt 0 ]; then
    total=$(( $(date +%s) - started ))
    [ "$total" -lt 0 ] && total=0
    summary="claude-timestamp: session lasted $(ct_format_duration "$total") over $turns turn"
    [ "$turns" -eq 1 ] || summary="${summary}s"
    summary="${summary}, $(ct_format_duration "$waited") of it waiting."
    jq -n --arg msg "$summary" '{systemMessage: $msg}'
  fi
fi

ct_clear_state "$session_id"
exit 0
