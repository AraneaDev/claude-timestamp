#!/usr/bin/env bash
# MessageDisplay hook -- user-facing, display-only.
#
# Prepends a local-time marker to each assistant message on screen. Claude Code
# documents this event as display-only: the stored transcript and what the model
# sees are both untouched, so the marker cannot confuse Claude.
#
# The event fires repeatedly as a message streams, with a zero-based `index`
# per batch of newly completed lines. We stamp index 0 and emit nothing at all
# for the rest -- Claude Code's documented behaviour is to display the original
# delta when a hook returns no displayContent, so echoing the delta back would
# be a wasted jq round trip on every batch of every message.
#
# Times come from `date`, never jq's `now|strftime`, which always renders UTC.
set -euo pipefail

# No jq: emit nothing and exit 0, which displays the message unchanged. Never
# swallow assistant output.
command -v jq >/dev/null 2>&1 || exit 0

input="$(cat)"

# One cheap jq call decides whether there is any work to do at all.
read -r index session_id <<< "$(printf '%s' "$input" | jq -r '"\(.index // 0) \(.session_id // "")"')"
[ "$index" = "0" ] || exit 0

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/config.sh"
ct_load_config

marker="$(ct_now "$CT_DISPLAY_FORMAT")"

if [ "$CT_ELAPSED" = "on" ] && state_file="$(ct_state_file "$session_id")" && [ -r "$state_file" ]; then
  started="$(cat "$state_file")"
  case "$started" in
    ''|*[!0-9]*) ;;                       # unreadable stamp: just skip elapsed
    *)
      elapsed=$(( $(date +%s) - started ))
      # Negative means the clock moved backwards mid-turn; show nothing rather
      # than a nonsense duration.
      [ "$elapsed" -ge 0 ] && marker="$marker $(ct_format_elapsed "$elapsed")"
      ;;
  esac
fi

marker="$(ct_color_start "$CT_COLOR")[$marker]$(ct_color_end "$CT_COLOR")"

printf '%s' "$input" | jq --arg marker "$marker " '{
  hookSpecificOutput: {
    hookEventName: "MessageDisplay",
    displayContent: ($marker + .delta)
  }
}'
