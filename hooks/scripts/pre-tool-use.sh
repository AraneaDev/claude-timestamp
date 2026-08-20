#!/usr/bin/env bash
# PreToolUse hook -- records when a tool call started.
#
# Half of the optional tool-timing feature; post-tool-use.sh closes the pair.
# Off by default, because unlike everything else in this plugin these two hooks
# fire per tool call rather than per message.
#
# Never blocks or alters a tool call: it writes one file and exits 0 whatever
# happens.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/config.sh"
ct_load_config

# The master switch. Everything below draws on screen, writes state, or talks
# to the model, and off means none of it.
[ "$CT_ENABLED" = "on" ] || exit 0
[ "$CT_TOOL_TIMING" = "on" ] || exit 0
# Checked last, so the common case -- tool timing off -- costs a bash builtin
# rather than a jq process fork on every tool call.
command -v jq >/dev/null 2>&1 || exit 0

input="$(cat)"
read -r session_id tool_use_id <<< "$(printf '%s' "$input" \
  | jq -r '"\(.session_id // "-") \(.tool_use_id // "")"')"

if state_file="$(ct_tool_state_file "$session_id" "$tool_use_id")"; then
  mkdir -p "$(ct_state_dir)"
  ct_now_precise > "$state_file"
fi

exit 0
