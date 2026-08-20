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
# for the elapsed marker and session-end.sh reads for the summary, and clears
# the per-turn tool log so ct_dominant_tool cannot blame a tool call from the
# previous turn. Those two happen even when context injection is off, because
# the settings are independent: display-only users still want to see how long
# a turn took and what made it slow. The away string below is the one thing
# that does not: it exists only to tell the model, so it is gated on
# INJECT_CONTEXT along with everything else that talks to it.
#
# Times come from `date`, never jq's `now|strftime`, which always renders UTC.
set -euo pipefail

# No jq: add no context rather than failing the prompt.
command -v jq >/dev/null 2>&1 || exit 0

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/config.sh"

input="$(cat)"

# The payload carries the directory the conversation is about, which is what
# decides whether a project has its own settings.
IFS=$'\x1f' read -r session_id cwd <<< "$(printf '%s' "$input" \
  | jq -r '[(.session_id // ""), (.cwd // "")] | join("\u001f")')"

ct_load_config "$cwd"

# The master switch. Everything below draws on screen, writes state, or talks
# to the model, and off means none of it.
[ "$CT_ENABLED" = "on" ] || exit 0

# The turn start is recorded unconditionally: the elapsed marker and the
# end-of-session summary both read it, and they are configured independently,
# so gating the write on either one would silently break the other.
if state_file="$(ct_state_file "$session_id")"; then
  mkdir -p "$(ct_state_dir)"
  now="$(date +%s)"
  printf '%s' "$now" > "$state_file"
  # First prompt of the session marks its beginning.
  [ -r "${state_file}.start" ] || printf '%s' "$now" > "${state_file}.start"

  if [ "$CT_SUMMARY" = "on" ]; then
    # A turn is a prompt, not an assistant message: a single prompt can produce
    # several messages as tools run, and counting those reported one prompt as
    # several turns.
    printf '%s' "$(( $(ct_read_counter "${state_file}.turns") + 1 ))" > "${state_file}.turns"
    # Waiting is accumulated per turn, and elapsed is measured from this
    # moment, so the running total for this turn starts at zero.
    printf '0' > "${state_file}.counted"
  fi

  # Cleared unconditionally rather than under TOOL_TIMING, so switching tool
  # timing on mid-session cannot inherit a log from before it was on.
  if turn_log="$(ct_turn_tool_log "$session_id")"; then
    : > "$turn_log"
  fi
fi

[ "$CT_INJECT_CONTEXT" = "false" ] && exit 0

# How long the user was away, when they were. The gap is measured from the last
# assistant message, which message-display.sh records, so this is the same
# break the idle divider draws on screen. Told to the model because a reply
# that carries on mid-thought after three hours reads as though nothing
# happened.
away=""
if [ -n "${state_file:-}" ] && [ "$CT_IDLE_AFTER" -gt 0 ] 2>/dev/null; then
  last="$(ct_read_counter "${state_file}.last")"
  if [ "$last" -gt 0 ]; then
    gap=$(( $(date +%s) - last ))
    if [ "$gap" -ge "$CT_IDLE_AFTER" ]; then
      away=", after a $(ct_humanize_gap "$gap") break"
    fi
  fi
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
