#!/usr/bin/env bash
# UserPromptSubmit hook -- model-facing.
#
# Tells Claude the local time each prompt was sent. Claude Code wraps the
# string in a <system-reminder>, so the model reads it as passive metadata and
# never as part of what the user typed. The system prompt already carries
# today's date, so this sends time + zone only -- no redundant date, fewer
# tokens.
#
# This hook also stamps the start of the turn, which message-display.sh reads
# for the elapsed marker and session-end.sh reads for the summary. That happens
# even when context injection is off, because the settings are independent:
# display-only users still want to see how long a turn took.
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
fi

[ "$CT_INJECT_CONTEXT" = "false" ] && exit 0

# The zone is always appended, whatever the chosen format, so the model can
# still resolve the offset when the format itself omits it.
ts="$(ct_now "$CT_CONTEXT_FORMAT") $(ct_zone)"

jq -n --arg ts "$ts" '{
  hookSpecificOutput: {
    hookEventName: "UserPromptSubmit",
    additionalContext: ("Message sent at local time " + $ts)
  }
}'
