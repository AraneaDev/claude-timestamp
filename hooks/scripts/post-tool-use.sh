#!/usr/bin/env bash
# PostToolUse and PostToolUseFailure hook -- records what a tool call cost.
#
# Appends one line, "<tool name> <seconds> <ok|fail>", to a per-session log that
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

CT_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
source "$CT_LIB/config.sh"
source "$CT_LIB/state.sh"
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

# Absent, or not composed entirely of digits: there is no usable duration, so
# the call goes unrecorded rather than logged with a made-up number. A
# genuine zero passes this check and is recorded like any other value --
# "took no time" is real information, not a reason to drop the line.
case "$ms" in ''|*[!0-9]*) exit 0 ;; esac

# Force base 10. "$ms" is all digits at this point, but a leading zero --
# e.g. "0800" -- makes bash arithmetic read it as octal, where 8 is not a
# valid digit, aborting the hook; "10#" pins the base so the digits are read
# as the decimal the sender meant. Do not remove this as noise.
ms=$((10#$ms))

# Milliseconds to seconds, in the shell rather than through awk, so a hook that
# already fires once per tool call does not fork a second time to divide by a
# thousand.
printf -v seconds '%d.%03d' "$((ms / 1000))" "$((ms % 1000))"

log="$(ct_tool_log "$session_id")" || exit 0
case "$tool_name" in ''|*[![:alnum:]_-]*) tool_name="unknown" ;; esac

# The outcome is the third field on the line rather than a counter of its own.
# Tool calls run in parallel, so a counter would be a read-modify-write on a
# file several copies of this hook hold open at once, which is the lost-update
# hazard the log's own append-only shape exists to avoid.
outcome=ok
[ "$event" = "PostToolUseFailure" ] && outcome=fail

mkdir -p "$(ct_state_dir)"
printf '%s %s %s\n' "$tool_name" "$seconds" "$outcome" >> "$log"

# The session-wide log answers "what made this session slow"; this one
# answers "what made this reply slow". Both need the same line.
if turn_log="$(ct_turn_tool_log "$session_id")"; then
  printf '%s %s %s\n' "$tool_name" "$seconds" "$outcome" >> "$turn_log"
fi

exit 0
