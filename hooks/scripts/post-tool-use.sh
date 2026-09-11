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
# It also tells the model two things, as additionalContext: that the call just
# finished was slow (SLOW_TOOL_AFTER), and how long the open turn has run
# (HEARTBEAT_AFTER). Both are staged by the prompt hook already resolved
# against INJECT_CONTEXT and ENABLED, so this hook reads a number per note
# rather than loading configuration for them.
#
# Never alters tool output: it writes its own state, may add context, and exits 0.
#
# Invoked as `bash <this script>` (see hooks.json), so it does not depend on
# the executable bit surviving clones, zips, or Windows checkouts.
set -euo pipefail

CT_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
source "$CT_LIB/config.sh"
source "$CT_LIB/state.sh"

# Decide with a glob, before anything forks. The gate itself lives in
# lib/state.sh, next to the flags it reads and where it can be tested: this
# hook's output is identical whether the answer is yes or no, so the only thing
# an end-to-end test could observe is the cost the gate exists to avoid.
ct_timing_wanted || exit 0

# No jq: nothing can be read out of the payload, including the session id this
# hook needs to find its own state.
command -v jq >/dev/null 2>&1 || exit 0

# agent_id is non-empty only inside a subagent, the same test stop.sh and
# message-display.sh apply. jq reads the payload from stdin itself: holding it
# in a variable first cost a `cat` and a subshell on every tool call, for a
# value nothing else here reads.
IFS=$'\x1f' read -r session_id tool_name event ms agent_id <<< "$(jq -r \
  '[(.session_id // "-"), (.tool_name // ""), (.hook_event_name // ""), (.duration_ms // "" | tostring), (.agent_id // "")] | join("\u001f")')"

# The prompt hook resolved the settings against the payload's cwd and left
# them here, so this hook honours the same project config the marker does
# without resolving one itself. A session whose first prompt predates this
# version has no staged answer; fall back to the process's own view, which is
# what this hook used to do unconditionally. Such a session gets no notes
# until its next prompt stages their thresholds.
#
# Every flag is read through the _var form, which assigns _CT_FLAG rather than
# printing: this runs on every tool call, and a command substitution per flag
# was a subshell each.
ct_read_flag_var "$session_id" "enabled";    ct_enabled="$_CT_FLAG"
ct_read_flag_var "$session_id" "tooltiming"; ct_timing="$_CT_FLAG"
if [ -z "$ct_enabled" ] || [ -z "$ct_timing" ]; then
  ct_load_config
  ct_enabled="${ct_enabled:-$CT_ENABLED}"
  ct_timing="${ct_timing:-$CT_TOOL_TIMING}"
fi

[ "$ct_enabled" = "on" ] || exit 0

case "$tool_name" in ''|*[![:alnum:]_-]*) tool_name="unknown" ;; esac

# The outcome is the third field on the line rather than a counter of its own.
# Tool calls run in parallel, so a counter would be a read-modify-write on a
# file several copies of this hook hold open at once, which is the lost-update
# hazard the log's own append-only shape exists to avoid.
outcome=ok
[ "$event" = "PostToolUseFailure" ] && outcome=fail

# Absent, or not composed entirely of digits: there is no usable duration, so
# the call goes unrecorded rather than logged with a made-up number, and no
# slow-tool note can be based on it. A genuine zero is real information.
#
# Force base 10. A leading zero -- e.g. "0800" -- makes bash arithmetic read
# it as octal, where 8 is not a valid digit, aborting the hook; "10#" pins the
# base so the digits are read as the decimal the sender meant. Do not remove
# this as noise.
#
# More than 15 digits -- over 30,000 years of milliseconds -- is not a real
# duration, and bash arithmetic would wrap it silently into a wrong or
# negative one. It is treated the same as a missing value.
case "$ms" in
  ''|*[!0-9]*) ms="" ;;
  *) if [ "${#ms}" -gt 15 ]; then ms=""; else ms=$((10#$ms)); fi ;;
esac

# The two log paths are ct_tool_log and ct_turn_tool_log, spelled out from
# ct_state_file_var so that resolving them forks nothing.
if [ "$ct_timing" = "on" ] && [ -n "$ms" ] && ct_state_ready \
   && ct_state_file_var "$session_id"; then
  log="${_CT_STATE_FILE}.tools"
  # Milliseconds to seconds, in the shell rather than through awk, so a hook
  # that already fires once per tool call does not fork a second time to
  # divide by a thousand.
  printf -v seconds '%d.%03d' "$((ms / 1000))" "$((ms % 1000))"
  printf '%s %s %s\n' "$tool_name" "$seconds" "$outcome" >> "$log"

  # The session-wide log answers "what made this session slow"; this one
  # answers "what made this reply slow". Both need the same line.
  printf '%s %s %s\n' "$tool_name" "$seconds" "$outcome" >> "${_CT_STATE_FILE}.turntools"
fi

# What the model is told. Both notes are facts only; the time-awareness skill
# is where the advice about them lives. The slow-tool note follows SUBAGENTS,
# the same switch that decides whether a subagent's messages are stamped --
# but the heartbeat is main-conversation only, whatever SUBAGENTS says.
# Subagents share the session's heartbeat record (<state>.hb) with the main
# conversation rather than keeping one of their own, so letting a subagent's
# call claim an interval would leave the main conversation's next call
# finding it already told; the elapsed time it reports is the turn's, which
# belongs to the main conversation regardless of which call happens to
# observe it.
#
# The note builders assign _CT_NOTE rather than print, so a call with nothing
# to say forks nothing to find that out. `|| :` keeps a failure inside one of
# them from ending the hook under errexit: a note that cannot be built is a
# note not sent.
note=""
subagent_notes=""
if [ -n "$agent_id" ]; then
  ct_read_flag_var "$session_id" "subagents"; subagent_notes="$_CT_FLAG"
fi
if [ -z "$agent_id" ] || [ "$subagent_notes" = "on" ]; then
  ct_read_flag_var "$session_id" "slowtool"
  ct_slow_tool_note_var "$tool_name" "$ms" "$outcome" "$_CT_FLAG" || :
  note="$_CT_NOTE"
fi
if [ -z "$agent_id" ]; then
  ct_read_flag_var "$session_id" "heartbeat"; hb_every="$_CT_FLAG"
  case "$hb_every" in
    ''|0|*[!0-9]*) ;;
    *)
      # The clock from the printf builtin where bash has one (4.2 and newer),
      # sparing the `date` process; bash 3.2, which macOS still ships, has
      # no %(...)T and keeps paying for it.
      if [ "${BASH_VERSINFO[0]}" -gt 4 ] \
         || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 2 ]; }; then
        printf -v now '%(%s)T' -1
      else
        now="$(date +%s)"
      fi
      ct_heartbeat_note_var "$session_id" "$now" "$hb_every" || :
      [ -n "$_CT_NOTE" ] && note="${note:+$note }$_CT_NOTE"
      ;;
  esac
fi

if [ -n "$note" ]; then
  jq -n --arg event "${event:-PostToolUse}" --arg note "$note" \
    '{hookSpecificOutput: {hookEventName: $event, additionalContext: $note}}'
fi

exit 0
