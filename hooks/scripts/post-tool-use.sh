#!/usr/bin/env bash
# PostToolUse and PostToolUseFailure hook -- closes out a tool call started by
# pre-tool-use.sh.
#
# Appends one line, "<tool name> <seconds>", to a per-session log that
# session-end.sh aggregates. Appending rather than maintaining a running tally
# is deliberate: tool calls run in parallel, so several copies of this hook can
# finish at once, and a read-modify-write on a shared counter would lose
# writes. A single short append does not.
#
# Never alters tool output: this hook only writes to its own state and exits 0.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/config.sh"
ct_load_config

[ "$CT_TOOL_TIMING" = "on" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

input="$(cat)"
IFS=$'\x1f' read -r session_id tool_use_id tool_name event <<< "$(printf '%s' "$input" \
  | jq -r '[(.session_id // "-"), (.tool_use_id // ""), (.tool_name // ""), (.hook_event_name // "")] | join("\u001f")')"

state_file="$(ct_tool_state_file "$session_id" "$tool_use_id")" || exit 0
[ -r "$state_file" ] || exit 0

started="$(cat "$state_file")"
rm -f "$state_file"

log="$(ct_tool_log "$session_id")" || exit 0
case "$tool_name" in ''|*[![:alnum:]_-]*) tool_name="unknown" ;; esac

mkdir -p "$(ct_state_dir)"
printf '%s %s\n' "$tool_name" "$(ct_duration_between "$started" "$(ct_now_precise)")" >> "$log"

# The same script serves both events, because a failed call is still a call
# that took time. Only the tally of failures differs.
if [ "$event" = "PostToolUseFailure" ]; then
  base="$(ct_state_file "$session_id")" || exit 0
  printf '%s' "$(( $(ct_read_counter "${base}.failed") + 1 ))" > "${base}.failed"
fi

exit 0
