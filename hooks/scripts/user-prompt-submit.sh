#!/usr/bin/env bash
# UserPromptSubmit hook -- model-facing.
#
# Tells Claude the local time each prompt was sent, and how long it was since
# the last reply when that gap is worth mentioning. Claude Code wraps the
# string in a <system-reminder>, so the model reads it as passive metadata and
# never as part of what the user typed. The system prompt already carries
# today's date, so this sends time + zone only -- no redundant date, fewer
# tokens.
#
# This hook also stamps the start of the turn, which message-display.sh reads
# for the elapsed marker and stop.sh reads to close it; closes out a turn that
# was interrupted before Stop could fire; and clears the per-turn tool log so
# ct_dominant_tool cannot blame a tool call from the previous turn. All three
# happen unconditionally and even when context injection is off: the counters
# feed SUMMARY and HISTORY, which are configured independently, so display-only
# users still want to see how long a turn took and what made it slow. The away
# string below is the one thing that does not: it exists only to tell the
# model, so it is gated on INJECT_CONTEXT along with everything else that talks
# to it.
#
# Times come from `date`, never jq's `now|strftime`, which always renders UTC.
set -euo pipefail

# No jq: add no context rather than failing the prompt.
command -v jq >/dev/null 2>&1 || exit 0

CT_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
source "$CT_LIB/config.sh"
source "$CT_LIB/state.sh"

input="$(cat)"

# The payload carries the directory the conversation is about, which is what
# decides whether a project has its own settings.
IFS=$'\x1f' read -r session_id cwd <<< "$(printf '%s' "$input" \
  | jq -r '[(.session_id // ""), (.cwd // "")] | join("\u001f")')"

ct_load_config "$cwd"

# The master switch. Everything below draws on screen, writes state, or talks
# to the model, and off means none of it.
[ "$CT_ENABLED" = "on" ] || exit 0

if state_file="$(ct_state_file "$session_id")"; then
  now="$(date +%s)"

  # A turn still open when the next prompt arrives ended without a Stop, which
  # is what an interrupt looks like from here. It contributes the part of
  # itself that was observed: up to the last message drawn on screen. This has
  # to happen before the new turn is opened, or the evidence is gone.
  ct_turn_close "$session_id" "$(ct_read_counter "${state_file}.last")"
  ct_record_away "$session_id" "$now"
  ct_turn_open "$session_id" "$now"

  # Cleared unconditionally rather than under TOOL_TIMING, so switching tool
  # timing on mid-session cannot inherit a log from before it was on.
  if turn_log="$(ct_turn_tool_log "$session_id")"; then
    : > "$turn_log"
  fi
fi

[ "$CT_INJECT_CONTEXT" = "false" ] && exit 0

# How long the user was away, when they were. The same figure the divider
# draws, from the same measurement, so the screen and the model never disagree.
# Told to the model because a reply that carries on mid-thought after three
# hours reads as though nothing happened.
away=""
if [ -n "${state_file:-}" ]; then
  gap="$(ct_read_counter "${state_file}.away")"
  [ "$gap" -gt 0 ] && away=", after a $(ct_humanize_gap "$gap") break"
fi

# The zone is always appended, whatever the chosen format, so the model can
# still resolve the offset when the format itself omits it.
ts="$(ct_now "$CT_CONTEXT_FORMAT") $(ct_zone)"

jq -n --arg ts "$ts" --arg away "$away" '{
  hookSpecificOutput: {
    hookEventName: "UserPromptSubmit",
    additionalContext: ("Message sent at local time " + $ts + $away)
  }
}'
