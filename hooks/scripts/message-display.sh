#!/usr/bin/env bash
# MessageDisplay hook -- user-facing, display-only.
#
# Prepends a local-time marker to each assistant message on screen. Claude Code
# documents this event as display-only: the stored transcript and what the model
# sees are both untouched, so the marker cannot confuse Claude.
#
# It draws, and it keeps only what drawing needs: the last message's time and
# the last date rendered, both of which the idle divider and the midnight
# rollover read. The session's accounts are kept by the prompt and stop hooks,
# which is where a turn actually begins and ends.
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

# MessageDisplay fires once per batch of newly completed lines, and only the
# first batch of a message is stamped, so the overwhelming majority of
# invocations have nothing to do. Deciding that in the shell keeps them from
# forking jq to find out.
#
# This is a filter, not a parser: it may only skip what it can positively
# prove is a later batch. It can prove that when the payload contains an
# "index" key whose value is not 0. Absence of the key is not proof of
# anything -- the downstream jq call treats a missing index as 0 via
# `.index // 0` -- so an absent key must fall through to the parse, same as
# a delta whose own text happens to contain the pattern: one extra fork,
# rejected by the parse below, which remains the only thing that decides.
# The patterns live in variables because bash 3.2 needs an unquoted
# expansion here to treat them as regexes rather than literals.
ct_has_index='"index"[[:space:]]*:'
ct_first_batch='"index"[[:space:]]*:[[:space:]]*0[[:space:],}]'
if [[ "$input" =~ $ct_has_index ]] && ! [[ "$input" =~ $ct_first_batch ]]; then
  exit 0
fi

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

# The master switch. Everything below draws on screen, writes state, or talks
# to the model, and off means none of it.
[ "$CT_ENABLED" = "on" ] || exit 0

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
    # Why it was slow, when that can be answered. Only tool timing collects
    # the data, so this follows TOOL_TIMING rather than adding a key of its
    # own: a marker that names the culprit is what tool timing is for.
    if [ "$CT_TOOL_TIMING" = "on" ] && [ -n "$state_file" ]; then
      if culprit="$(ct_dominant_tool "${state_file}.turntools" "$elapsed_secs")"; then
        inner="$inner · $culprit"
      fi
    fi
  else
    inner="$inner $elapsed"
  fi
fi

marker="${base_start}[${inner}]${base_end}"

# A gap since the previous message means you stepped away. Marked on its own
# line above the message, because MessageDisplay can only replace a delta --
# there is no way to draw a standalone separator between turns.
divider=""
if [ -n "$state_file" ]; then
  last_file="${state_file}.last"
  # Guarded on IDLE_AFTER because the divider and the .idle total are its
  # display feature; the timestamp below is not optional even when this is
  # off, because a turn that ends without a Stop is reconciled from .last, so
  # switching the divider off must not switch off the evidence the summary
  # needs.
  if [ "$CT_IDLE_AFTER" -gt 0 ] 2>/dev/null; then
    last="$(ct_read_counter "$last_file")"
    if [ "$last" -gt 0 ]; then
      gap=$((now - last))
      if [ "$gap" -ge "$CT_IDLE_AFTER" ]; then
        divider="$(ct_paint "$CT_COLOR" "-- $(ct_humanize_gap "$gap") later --")
"
        # Total the breaks so the summary can separate time you spent waiting on
        # a reply from time you were not at the keyboard at all.
        if [ "$CT_SUMMARY" = "on" ]; then
          printf '%s' "$(( $(ct_read_counter "${state_file}.idle") + gap ))" > "${state_file}.idle"
        fi
      fi
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
