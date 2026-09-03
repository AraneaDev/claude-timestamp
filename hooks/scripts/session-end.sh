#!/usr/bin/env bash
# SessionEnd hook -- user-facing.
#
# Reports what the session cost in wall-clock terms, then removes the state
# files it accumulated. Most of what it reports comes from counters that
# user-prompt-submit.sh and stop.sh maintain per turn, but a session can end
# mid-turn, with no Stop to close it, so this hook also closes that last turn
# itself before reading anything.
#
# "Waiting" is the sum of prompt-to-reply times, which is the part of the
# session you actually spent watching a cursor. The remainder of the elapsed
# total is your own thinking, reading, and typing.
#
# Invoked as `bash <this script>` (see hooks.json), so it does not depend on
# the executable bit surviving clones, zips, or Windows checkouts.
set -euo pipefail

command -v jq >/dev/null 2>&1 || exit 0

CT_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
source "$CT_LIB/config.sh"
source "$CT_LIB/state.sh"

input="$(cat)"
IFS=$'\x1f' read -r session_id cwd <<< "$(printf '%s' "$input" \
  | jq -r '[(.session_id // ""), (.cwd // "")] | join("\u001f")')"

ct_load_config "$cwd"

# The master switch gates everything that draws on screen or talks to the
# model, but not cleanup: a session switched off mid-way still accumulated
# state files, and skipping the clear here would strand them until the 7-day
# sweep instead of at the session's own end. ct_clear_state returns 0 on a
# bad or empty session id, so this is safe either way.
if [ "$CT_ENABLED" != "on" ]; then
  ct_clear_state "$session_id"
  exit 0
fi

state_file="$(ct_state_file "$session_id")" || { ct_clear_state "$session_id"; exit 0; }

# A session can end mid-turn, which leaves a turn no Stop ever closed. That is
# the same reconciliation the next prompt would have done, at the one other
# place a turn can be abandoned, so the last turn of a session is not silently
# dropped from its own summary.
ct_turn_close "$session_id" "$(ct_read_counter "${state_file}.last")"

ct_session_totals "$session_id"

# Failures are counted out of the tool log rather than from a counter, so
# concurrent tool calls appending at once are all seen. A log that is absent
# or was never written means no failures to report.
log="${state_file}.tools"
failed=0
[ -s "$log" ] && failed="$(awk '$3 == "fail" { n++ } END { print n + 0 }' "$log")"

total=0
if [ "$_CT_START" -gt 0 ]; then
  total=$(( $(date +%s) - _CT_START ))
  [ "$total" -lt 0 ] && total=0
fi

summary=""
if [ "$CT_SUMMARY" = "on" ] && [ "$_CT_START" -gt 0 ] && [ "$_CT_TURNS" -gt 0 ]; then
  summary="claude-timestamp: session lasted $(ct_format_duration "$total") over $_CT_TURNS turn"
  [ "$_CT_TURNS" -eq 1 ] || summary="${summary}s"
  summary="${summary}, $(ct_format_duration "$_CT_WAIT") of it waiting"
  # Only mentioned when there was a break worth mentioning, so a session you
  # sat through end to end does not read as though it had gaps.
  [ "$_CT_IDLE" -gt 0 ] && summary="${summary}, $(ct_format_duration "$_CT_IDLE") away"
  summary="${summary}."
fi

# Tool timings, when they were being collected. Summed per tool and reported
# worst-first, because the question this answers is "what made this session
# slow", not "how long did any single call take".
if [ "$CT_SUMMARY" = "on" ] && [ "$CT_TOOL_TIMING" = "on" ] && [ -s "$log" ]; then
  # `|| true`: on a log with many distinct tools, `head -3` can close the pipe
  # before `sort` is done writing, which sends `sort` SIGPIPE even though
  # every line `head` needed was already delivered. Under this script's own
  # errexit/pipefail (see the top of the file), that nonzero exit would abort
  # the hook right here -- before ct_history_append and before ct_clear_state
  # -- for the same reason ct_tool_digest in lib/config.sh needs it. This is
  # the more common way to hit it, since SUMMARY and TOOL_TIMING both on is
  # the ordinary way to have TOOL_TIMING on at all.
  tools="$(awk '{ sum[$1] += $2; n[$1]++ }
                END { for (t in sum) printf "%.3f\t%s\t%d\n", sum[t], t, n[t] }' "$log" \
           | sort -rn | head -3 \
           | awk -F'\t' '{
               calls = ($3 == 1) ? "1 call" : $3 " calls"
               printf "%s%s %.1fs (%s)", (NR > 1 ? ", " : ""), $2, $1, calls
             }')" || true
  if [ -n "$tools" ]; then
    [ -n "$summary" ] && summary="$summary"$'\n'
    summary="${summary}slowest tools: $tools"
    if [ "$failed" -gt 0 ]; then
      summary="${summary}. $failed failed"
    fi
  fi
fi

# See session-start.sh: an `if` rather than an AND-list, so the exit status
# does not depend on the `exit 0` further down staying where it is.
if [ -n "$summary" ]; then
  jq -n --arg msg "$summary" '{systemMessage: $msg}'
fi

# Record the session before its state is cleared, so /timestamps stats has
# something to work from once the session is gone. Independent of SUMMARY:
# they are separate settings and share only the counters underneath.
if [ "$CT_HISTORY" = "on" ] && [ "$_CT_START" -gt 0 ] && [ "$_CT_TURNS" -gt 0 ]; then
  # Each column is gated on the setting that fills it and on nothing else.
  #
  # In particular the digest is gated on TOOL_TIMING alone, never on SUMMARY.
  # The aggregation above shares this log and does test SUMMARY, because it
  # feeds a line printed on screen. This one feeds the history, which is a
  # separate setting: see state.sh:402 for what coupling the two cost the
  # last time it happened.
  hist_project=""
  [ "$CT_PROJECTS" = "on" ] && hist_project="$(ct_project_name "$cwd")"
  hist_tools=""
  [ "$CT_TOOL_TIMING" = "on" ] && hist_tools="$(ct_tool_digest "$log")"
  ct_history_append "$total" "$_CT_TURNS" "$_CT_WAIT" "$_CT_IDLE" "$failed" \
    "$hist_project" "$hist_tools"
fi

ct_clear_state "$session_id"
exit 0
