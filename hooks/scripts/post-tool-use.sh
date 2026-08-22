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

# Decide with a glob, before anything forks.
#
# This hook runs on every tool call, and the README promises TOOL_TIMING is the
# only setting that costs anything at that rate. Learning the session id needs
# jq, and forking jq to discover there was nothing to do would make every user
# running the default pay for a feature they have switched off. A sentinel is
# staged per session while tool timing is on, so no match here means no session
# wants timing and this hook is finished. A match means SOME session does; which
# one still needs the payload, and that is where the fork earns its place.
#
# Conservative on purpose: one session with timing on makes every concurrent
# session pay the parse. Over-recording is recoverable, a missed measurement is
# not.
ct_state_dir_var
_ct_timing_wanted=0
for _ct_f in "$_CT_STATE_DIR"/*.timing-on; do
  [ -e "$_ct_f" ] && _ct_timing_wanted=1
  break
done

# A session whose first prompt predates this fix has a turn file but never
# staged an .enabled sibling, so it cannot appear in the glob above -- it has
# no way to say what it wants. Rather than let the gate answer "no session
# wants timing" on its behalf, its calls fall through to the same jq parse and
# config resolution every call used to pay, until its next prompt catches it up
# and stages a real answer.
#
# This scan's cost grows with the number of sessions in state (measured: ~5ms
# at 1, ~9ms at 100, ~18ms at 300, bounded by the 7-day prune) -- kept anyway.
# A missed tool-call measurement is an accuracy loss in the exact number this
# feature exists to produce; a few extra milliseconds of hook overhead on an
# already-cheap path is not something this plugin is optimising away.
if [ "$_ct_timing_wanted" -eq 0 ]; then
  for _ct_f in "$_CT_STATE_DIR"/*; do
    # Match the ENTRY name, not the whole path. $_ct_f is absolute, and a
    # $TMPDIR with a dot anywhere in it -- macOS hands out
    # /var/folders/xy/....../T by default -- makes `*.*` match every entry, so
    # the scan skips every session and tool timing never turns on for a
    # session that predates the staged flag.
    case "${_ct_f##*/}" in
      *.*) continue ;;
    esac
    [ -e "$_ct_f" ] || continue
    [ -e "${_ct_f}.enabled" ] || { _ct_timing_wanted=1; break; }
  done
fi

[ "$_ct_timing_wanted" -eq 1 ] || exit 0

# No jq: nothing can be read out of the payload, including the session id this
# hook needs to find its own state.
command -v jq >/dev/null 2>&1 || exit 0

input="$(cat)"
IFS=$'\x1f' read -r session_id tool_name event ms <<< "$(printf '%s' "$input" \
  | jq -r '[(.session_id // "-"), (.tool_name // ""), (.hook_event_name // ""), (.duration_ms // "" | tostring)] | join("\u001f")')"

# The prompt hook resolved both settings against the payload's cwd and left
# them here, so this hook honours the same project config the marker does
# without resolving one itself. A session whose first prompt predates this
# version has no staged answer; fall back to the process's own view, which is
# what this hook used to do unconditionally.
ct_enabled="$(ct_read_flag "$session_id" "enabled")"
ct_timing="$(ct_read_flag "$session_id" "tooltiming")"
if [ -z "$ct_enabled" ] || [ -z "$ct_timing" ]; then
  ct_load_config
  ct_enabled="${ct_enabled:-$CT_ENABLED}"
  ct_timing="${ct_timing:-$CT_TOOL_TIMING}"
fi

[ "$ct_enabled" = "on" ] || exit 0
[ "$ct_timing" = "on" ] || exit 0

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

ct_state_ready || exit 0
printf '%s %s %s\n' "$tool_name" "$seconds" "$outcome" >> "$log"

# The session-wide log answers "what made this session slow"; this one
# answers "what made this reply slow". Both need the same line.
if turn_log="$(ct_turn_tool_log "$session_id")"; then
  printf '%s %s %s\n' "$tool_name" "$seconds" "$outcome" >> "$turn_log"
fi

exit 0
