#!/usr/bin/env bash
# MessageDisplay hook -- user-facing, display-only.
#
# Prepends a local-time marker to each assistant message on screen. Claude Code
# documents this event as display-only: the stored transcript and what the model
# sees are both untouched, so the marker cannot confuse Claude.
#
# It draws, and it keeps only what drawing needs: the last message's time and
# the last date rendered. The idle divider and the midnight rollover read
# those, and the last message's time has a second reader -- the prompt hook,
# which falls back to it to close a turn that ended in an interrupt rather
# than a Stop. The session's accounts are kept by the prompt and stop hooks,
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
# The same is true of a key present with a non-numeric value -- null, false,
# a quoted "0" -- which `.index // 0` also coerces to 0: the guard requires a
# digit right after the colon, so anything else falls through to the parse
# rather than being mistaken for proof of a later batch.
# The patterns live in variables because bash 3.2 needs an unquoted
# expansion here to treat them as regexes rather than literals.
ct_has_index='"index"[[:space:]]*:[[:space:]]*[0-9]'
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

CT_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
source "$CT_LIB/config.sh"
source "$CT_LIB/state.sh"
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
date_part=""
if [ "$CT_DATE_ROLLOVER" = "on" ] && [ -n "$state_file" ]; then
  today="$(ct_now '%Y-%m-%d')"
  date_file="${state_file}.date"
  if [ -r "$date_file" ]; then
    previous="$(cat "$date_file")"
    [ -n "$previous" ] && [ "$previous" != "$today" ] && date_part="$(ct_now '%b %d')"
  fi
  if ct_state_ready; then
    printf '%s' "$today" > "$date_file"
  fi
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

# Build the marker from MARKER. Each part is painted before it reaches the
# renderer, which is therefore purely structural and never needs to know a
# colour name. An absent part is passed as the empty string, which is how a
# {...} group in the template learns that it should disappear.
ct_color_seq "$CT_COLOR"; base_start="$_CT_SEQ"
base_end=""; [ -n "$base_start" ] && base_end=$'\033[0m'

# The duration wears SLOW_COLOR once a turn crosses SLOW_AFTER, whatever
# ELAPSED_COLOR says. That override is the feature rather than the styling, so
# the more specific setting wins.
elapsed_color="$CT_ELAPSED_COLOR"
tool_part=""
if [ -n "$elapsed" ] && [ "$CT_SLOW_AFTER" -gt 0 ] 2>/dev/null && [ -n "$elapsed_secs" ] \
   && [ "$elapsed_secs" -ge "$CT_SLOW_AFTER" ]; then
  elapsed_color="$CT_SLOW_COLOR"
  # Why it was slow, when that can be answered. Only tool timing collects the
  # data, so this follows TOOL_TIMING rather than adding a key of its own.
  if [ "$CT_TOOL_TIMING" = "on" ] && [ -n "$state_file" ]; then
    if culprit="$(ct_dominant_tool "${state_file}.turntools" "$elapsed_secs")"; then
      tool_part="$culprit"
    fi
  fi
fi

ct_paint_part "$CT_TIME_COLOR" "$time_part"    "$CT_COLOR"; painted_time="$_CT_PART"
ct_paint_part "$elapsed_color" "$elapsed"      "$CT_COLOR"; painted_elapsed="$_CT_PART"
ct_paint_part "$CT_TOOL_COLOR" "$tool_part"    "$CT_COLOR"; painted_tool="$_CT_PART"
ct_paint_part "$CT_TIME_COLOR" "$date_part"    "$CT_COLOR"; painted_date="$_CT_PART"

ct_render_marker "$CT_MARKER_TEMPLATE" \
  "$painted_time" "$painted_elapsed" "$painted_tool" "$painted_date"

# A MARKER that renders empty -- MARKER=, or MARKER=%elapsed with ELAPSED=off
# -- passes validation and would otherwise still leave the trailing separator
# space behind: the prefix becomes an escape, a space, an escape, and every
# message is indented by one space with no marker to explain it. Emitting no
# prefix at all when there is nothing to show keeps that space tied to an
# actual marker rather than being unconditional.
marker=""
[ -n "$CT_MARKER" ] && marker="${base_start}${CT_MARKER}${base_end} "

# A gap since the previous turn means you stepped away. Marked on its own line
# above the message, because MessageDisplay can only replace a delta -- there
# is no way to draw a standalone separator between turns.
#
# The figure is measured and accumulated by the prompt hook, which is the only
# place both ends of the gap are known. This hook draws it and clears it, so a
# break is marked exactly once.
divider=""
if [ -n "$state_file" ]; then
  if gap="$(ct_take_away "$session_id")" && [ -n "$gap" ]; then
    divider="$(ct_paint "$CT_COLOR" "-- $(ct_humanize_gap "$gap") later --")
"
  fi
  ct_note_message "$session_id" "$now"
fi

printf '%s' "$input" | jq --arg prefix "${divider}${marker}" '{
  hookSpecificOutput: {
    hookEventName: "MessageDisplay",
    displayContent: ($prefix + .delta)
  }
}'
