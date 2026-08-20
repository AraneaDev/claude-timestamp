#!/usr/bin/env bash
# PostToolUse and PostToolUseFailure hook -- records what a tool call cost.
#
# Appends one line, "<tool name> <seconds>", to a per-session log that
# session-end.sh aggregates, and the same line to a per-turn log the marker
# reads. Appending rather than maintaining a running tally is deliberate: tool
# calls run in parallel, so several copies of this hook can finish at once, and
# a read-modify-write on a shared counter would lose writes. A single short
# append does not.
#
# The duration comes from the payload rather than from a timestamp this plugin
# records itself. Claude Code measures the call alone, excluding the permission
# prompt and the hooks around it, which is the number worth reporting: a Bash
# call the user took ninety seconds to approve is not a ninety-second Bash call.
#
# The field is optional, so a harness that does not send one leaves the call
# untimed. That is the same place such a user was already in -- tool timing is
# off by default -- and it costs less than carrying a second measurement path
# for the case.
#
# Never alters tool output: this hook only writes to its own state and exits 0.
#
# Invoked as `bash <this script>` (see hooks.json), so it does not depend on
# the executable bit surviving clones, zips, or Windows checkouts.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/config.sh"
ct_load_config

# The master switch. Everything below writes state, and off means none of it.
[ "$CT_ENABLED" = "on" ] || exit 0
[ "$CT_TOOL_TIMING" = "on" ] || exit 0
# Checked last, so the common case -- tool timing off -- costs a bash builtin
# rather than a jq process fork on every tool call.
command -v jq >/dev/null 2>&1 || exit 0

input="$(cat)"
IFS=$'\x1f' read -r session_id tool_name event ms <<< "$(printf '%s' "$input" \
  | jq -r '[(.session_id // "-"), (.tool_name // ""), (.hook_event_name // ""), (.duration_ms // "" | tostring)] | join("\u001f")')"

# Absent, or present but not a whole number of milliseconds. Recording a zero
# would drag every average down and could name a tool that took no time as the
# reason a turn was slow, so the call goes unrecorded instead.
case "$ms" in ''|*[!0-9]*) exit 0 ;; esac

# Milliseconds to seconds, in the shell rather than through awk, so a hook that
# already fires once per tool call does not fork a second time to divide by a
# thousand.
printf -v seconds '%d.%03d' "$((ms / 1000))" "$((ms % 1000))"

log="$(ct_tool_log "$session_id")" || exit 0
case "$tool_name" in ''|*[![:alnum:]_-]*) tool_name="unknown" ;; esac

mkdir -p "$(ct_state_dir)"
printf '%s %s\n' "$tool_name" "$seconds" >> "$log"

# The session-wide log answers "what made this session slow"; this one
# answers "what made this reply slow". Both need the same line.
if turn_log="$(ct_turn_tool_log "$session_id")"; then
  printf '%s %s\n' "$tool_name" "$seconds" >> "$turn_log"
fi

# The same script serves both events, because a failed call is still a call
# that took time. Only the tally of failures differs.
if [ "$event" = "PostToolUseFailure" ]; then
  base="$(ct_state_file "$session_id")" || exit 0
  printf '%s' "$(( $(ct_read_counter "${base}.failed") + 1 ))" > "${base}.failed"
fi

exit 0
