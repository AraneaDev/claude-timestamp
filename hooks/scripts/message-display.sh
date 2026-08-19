#!/usr/bin/env bash
# MessageDisplay hook -- user-facing, display-only.
#
# Prepends a local-time marker to each assistant message on screen. Claude Code
# documents this event as display-only: the stored transcript and what the model
# sees are both untouched, so the marker cannot confuse Claude.
#
# The event fires repeatedly as a message streams, with a zero-based `index`
# per batch of newly completed lines. We stamp index 0 and emit nothing at all
# for the rest -- Claude Code displays the original delta when a hook returns no
# displayContent, so echoing the delta back would be a wasted jq round trip on
# every batch of every message.
#
# Times come from `date`, never jq's `now|strftime`, which always renders UTC.
set -euo pipefail

# No jq: emit nothing and exit 0, which displays the message unchanged. Never
# swallow assistant output.
command -v jq >/dev/null 2>&1 || exit 0

input="$(cat)"

# One cheap jq call decides whether there is any work to do at all.
# Split on the ASCII unit separator rather than a tab. cwd can contain spaces,
# and tab is IFS whitespace, which means bash collapses runs of it and silently
# drops empty fields: an absent agent_id would shift cwd into its place. A
# non-whitespace separator preserves empty fields, and 0x1f cannot appear in
# any of these values.
IFS=$'\x1f' read -r index session_id agent_id cwd <<< "$(printf '%s' "$input" \
  | jq -r '[(.index // 0 | tostring), (.session_id // "-"), (.agent_id // ""), (.cwd // "")] | join("\u001f")')"
[ "$index" = "0" ] || exit 0

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/config.sh"
ct_load_config "$cwd"

# Subagents can run several at a time, so their output interleaves and a marker
# on every message is noise rather than signal. Opt-out, not the default.
if [ "$CT_SUBAGENTS" = "off" ] && [ -n "$agent_id" ]; then
  exit 0
fi

state_file="$(ct_state_file "$session_id")" || state_file=""
now="$(date +%s)"

time_part="$(ct_now "$CT_DISPLAY_FORMAT")"

# A session that crosses midnight would otherwise show [00:03] with no hint
# that the day changed, which quietly breaks using these markers to reference
# earlier parts of a conversation. Show the date once, on the first message
# after the rollover.
if [ "$CT_DATE_ROLLOVER" = "on" ] && [ -n "$state_file" ]; then
  today="$(ct_now '%Y-%m-%d')"
  date_file="${state_file}.date"
  if [ -r "$date_file" ]; then
    previous="$(cat "$date_file")"
    [ -n "$previous" ] && [ "$previous" != "$today" ] && time_part="$(ct_now '%b %d') $time_part"
  fi
  mkdir -p "$(ct_state_dir)"
  printf '%s' "$today" > "$date_file"
fi

# Elapsed time for this turn, measured from when the prompt was submitted.
elapsed=""
elapsed_secs=""
if [ -n "$state_file" ] && [ -r "$state_file" ]; then
  started="$(ct_read_counter "$state_file")"
  if [ "$started" -gt 0 ]; then
    elapsed_secs=$((now - started))
    [ "$elapsed_secs" -lt 0 ] && elapsed_secs=""
  fi
fi

if [ "$CT_ELAPSED" = "on" ] && [ -n "$elapsed_secs" ]; then
  elapsed="$(ct_format_elapsed "$elapsed_secs")"
fi

# Running total of time spent waiting, for the end-of-session summary. Kept
# even when the elapsed marker is switched off, because the two settings are
# independent.
#
# elapsed_secs is measured from the prompt and therefore grows across a turn
# that runs tools, so only the increment since this turn's previous message is
# added. Summing the raw values would double-count, and could report more time
# waiting than the session lasted.
if [ "$CT_SUMMARY" = "on" ] && [ -n "$state_file" ] && [ -n "$elapsed_secs" ]; then
  mkdir -p "$(ct_state_dir)"
  counted="$(ct_read_counter "${state_file}.counted")"
  increment=$((elapsed_secs - counted))
  if [ "$increment" -gt 0 ]; then
    printf '%s' "$(( $(ct_read_counter "${state_file}.wait") + increment ))" > "${state_file}.wait"
    printf '%s' "$elapsed_secs" > "${state_file}.counted"
  fi
fi

# Build the marker. The elapsed portion gets its own colour once a turn crosses
# SLOW_AFTER, so a slow turn is something you notice rather than something you
# have to read. Painting only that portion means restoring the base colour
# afterwards, hence the explicit start/end rather than ct_paint here.
base_start="$(ct_color_start "$CT_COLOR")"
base_end="$(ct_color_end "$CT_COLOR")"

inner="$time_part"
if [ -n "$elapsed" ]; then
  if [ "$CT_SLOW_AFTER" -gt 0 ] 2>/dev/null && [ -n "$elapsed_secs" ] \
     && [ "$elapsed_secs" -ge "$CT_SLOW_AFTER" ]; then
    inner="$inner $(ct_paint "$CT_SLOW_COLOR" "$elapsed")$base_start"
  else
    inner="$inner $elapsed"
  fi
fi

marker="${base_start}[${inner}]${base_end}"

# A gap since the previous message means you stepped away. Marked on its own
# line above the message, because MessageDisplay can only replace a delta --
# there is no way to draw a standalone separator between turns.
divider=""
if [ -n "$state_file" ] && [ "$CT_IDLE_AFTER" -gt 0 ] 2>/dev/null; then
  last_file="${state_file}.last"
  last="$(ct_read_counter "$last_file")"
  if [ "$last" -gt 0 ]; then
    gap=$((now - last))
    if [ "$gap" -ge "$CT_IDLE_AFTER" ]; then
      divider="$(ct_paint "$CT_COLOR" "-- $(ct_humanize_gap "$gap") later --")
"
    fi
  fi
  mkdir -p "$(ct_state_dir)"
  printf '%s' "$now" > "$last_file"
fi

printf '%s' "$input" | jq --arg prefix "${divider}${marker} " '{
  hookSpecificOutput: {
    hookEventName: "MessageDisplay",
    displayContent: ($prefix + .delta)
  }
}'
