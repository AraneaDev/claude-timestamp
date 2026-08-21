#!/usr/bin/env bash
# Per-session state for claude-timestamp.
#
# Everything that reads or writes a file under the state directory lives here.
# config.sh parses, validates and renders; it does not know where state is or
# what it means. That split exists because the counters are shared: four hooks
# adjust them, each under its own view of which settings apply, and three
# defects came from there being no single place that said what they mean
# together.
#
# Sourcing this file has no side effects beyond defining functions.
#
# Source it after config.sh, always. Nothing here needs config.sh yet: every
# function below runs standalone today. But ct_record_away arrives shortly and
# reads CT_IDLE_AFTER, and an order that is only correct some of the time is
# worse than one that is always correct, because the day it stops being correct
# is the day something fails at load time in a hook nobody is watching. Do not
# "simplify" a consumer to source this file on its own.

# Elapsed-time state. One file per session, holding the epoch second the last
# prompt was submitted.
ct_state_dir() { printf '%s' "${TMPDIR:-/tmp}/claude-timestamp"; }

# Session ids come from the hook payload, so they are reduced to a safe
# character set before being used as a filename -- an id containing ../ must
# never be able to steer a write outside the state directory. Dots are dropped
# rather than kept, so no id can collapse to "." or ".." and address the state
# directory itself or its parent.
ct_state_file() {
  local sid
  sid="$(printf '%s' "${1:-}" | tr -cd 'A-Za-z0-9_-')"
  [ -n "$sid" ] || return 1
  printf '%s/%s' "$(ct_state_dir)" "$sid"
}

# The append-only log of completed tool calls for a session.
ct_tool_log() {
  local base
  base="$(ct_state_file "${1:-}")" || return 1
  printf '%s.tools' "$base"
}

# The tool log for the current turn only. The session-wide log answers "what
# made this session slow"; this one answers "what made this reply slow", which
# is a different question and needs a log that starts empty at every prompt.
ct_turn_tool_log() {
  local base
  base="$(ct_state_file "${1:-}")" || return 1
  printf '%s.turntools' "$base"
}

# Name the tool responsible for a slow turn, or say nothing.
#
# A tool has to account for at least half the turn before it is worth naming.
# Below that the marker would be pointing at something that was not the reason,
# which is worse than staying quiet. Returns non-zero when nothing dominates,
# so the caller can simply test it.
ct_dominant_tool() {
  local log="${1:-}" total="${2:-0}"
  [ -r "$log" ] || return 1
  case "$total" in ''|*[!0-9]*) return 1 ;; esac
  [ "$total" -gt 0 ] || return 1
  awk -v total="$total" '
    { sum[$1] += $2 }
    END {
      best = ""; top = 0
      for (t in sum) if (sum[t] > top) { top = sum[t]; best = t }
      if (top > total) top = total
      if (best == "" || top * 2 < total) exit 1
      if (top < 60) printf "%s %ds", best, int(top + 0.5)
      else          printf "%s %dm%02ds", best, int(top / 60), int(top) % 60
    }' "$log"
}

# Read a counter from the session state, defaulting to 0 when absent or
# corrupt, so a damaged state file degrades to "no history" rather than
# breaking the marker.
ct_read_counter() {
  local file="$1" value
  [ -r "$file" ] || { printf '0'; return 0; }
  value="$(cat "$file" 2>/dev/null)"
  case "$value" in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "$value" ;; esac
}

# Close the turn a prompt opened, adding what it cost to the running total of
# time spent waiting.
#
# A turn is open while its start file exists without a .closed sibling. The
# start file is left in place rather than removed, because message-display.sh
# reads it to render the elapsed marker and nothing orders a message's final
# flush against the event that ends a turn. Writing a sibling instead of
# deleting the file being read makes the interleaving irrelevant.
#
# Closing is idempotent. A hook can cause the model to run again, so a turn
# seeing two closes is a case to survive rather than one to assume away.
#
# The end time is a parameter rather than something read here, because the
# callers know different things: the Stop hook knows the turn is ending now,
# while a prompt reconciling a turn that was interrupted only knows when its
# last message was drawn.
ct_close_turn() {
  local state_file="${1:-}" ended="${2:-0}" started
  [ -n "$state_file" ] || return 0
  [ -r "$state_file" ] || return 0
  [ -e "${state_file}.closed" ] && return 0
  case "$ended" in ''|*[!0-9]*) return 0 ;; esac
  started="$(ct_read_counter "$state_file")"
  [ "$started" -gt 0 ] || return 0
  # A turn that ended before it began drew no message of its own, so it has
  # nothing to contribute. It is still closed: it is over either way.
  if [ "$ended" -gt "$started" ]; then
    printf '%s' "$(( $(ct_read_counter "${state_file}.wait") + ended - started ))" > "${state_file}.wait"
  fi
  printf '%s' "$ended" > "${state_file}.closed"
  return 0
}

# Open a turn.
#
# Everything here is unconditional. The counters are read by the summary and by
# the history, which are configured independently, so gating the write on
# either one silently breaks the other -- which is exactly what HISTORY=on with
# SUMMARY=off used to do: nothing was ever recorded, and --stats blamed HISTORY
# for it.
ct_turn_open() {
  local sid="${1:-}" now="${2:-0}" base
  base="$(ct_state_file "$sid")" || return 0
  case "$now" in ''|*[!0-9]*) return 0 ;; esac
  mkdir -p "$(ct_state_dir)" 2>/dev/null || return 0

  printf '%s' "$now" > "$base"
  rm -f "${base}.closed" 2>/dev/null || true
  [ -r "${base}.start" ] || printf '%s' "$now" > "${base}.start"
  printf '%s' "$(( $(ct_read_counter "${base}.turns") + 1 ))" > "${base}.turns"
  return 0
}

# Close a turn, by session id rather than by path, so no caller has to know the
# layout. Idempotent: a hook can cause the model to run again, so a turn seeing
# two closes is a case to survive rather than one to assume away.
ct_turn_close() {
  local sid="${1:-}" ended="${2:-0}" base
  base="$(ct_state_file "$sid")" || return 0
  ct_close_turn "$base" "$ended"
  return 0
}

# Record how long the user was away, and stage it for the divider.
#
# The gap runs from the previous turn's close to this prompt. Measuring from
# the previous message instead is wrong twice over: it swallows the tail of the
# previous turn, which ct_close_turn has already counted as waiting, and it
# cannot be measured until a reply renders, by which point the reply's own
# latency is inside the figure too.
#
# The staged value is written, never added to. A gap that no message ever draws
# -- a turn that produced nothing -- is replaced by the next prompt's, rather
# than accumulating into a divider that claims a break that never happened.
ct_record_away() {
  local sid="${1:-}" now="${2:-0}" base closed gap
  base="$(ct_state_file "$sid")" || return 0
  case "$now" in ''|*[!0-9]*) return 0 ;; esac
  [ "${CT_IDLE_AFTER:-0}" -gt 0 ] 2>/dev/null || return 0

  closed="$(ct_read_counter "${base}.closed")"
  [ "$closed" -gt 0 ] || return 0
  gap=$(( now - closed ))
  [ "$gap" -ge "$CT_IDLE_AFTER" ] || return 0

  mkdir -p "$(ct_state_dir)" 2>/dev/null || return 0
  printf '%s' "$(( $(ct_read_counter "${base}.idle") + gap ))" > "${base}.idle"
  printf '%s' "$gap" > "${base}.away"
  return 0
}

# Take the staged gap, if there is one. Printing and clearing in one call means
# a divider is drawn exactly once per break.
ct_take_away() {
  local sid="${1:-}" base gap
  base="$(ct_state_file "$sid")" || return 0
  gap="$(ct_read_counter "${base}.away")"
  rm -f "${base}.away" 2>/dev/null || true
  [ "$gap" -gt 0 ] || return 0
  printf '%s' "$gap"
  return 0
}

# Note that a message was drawn. Read by the prompt and session-end hooks to
# close a turn that ended in an interrupt rather than a Stop.
ct_note_message() {
  local sid="${1:-}" now="${2:-0}" base
  base="$(ct_state_file "$sid")" || return 0
  case "$now" in ''|*[!0-9]*) return 0 ;; esac
  mkdir -p "$(ct_state_dir)" 2>/dev/null || return 0
  printf '%s' "$now" > "${base}.last"
  return 0
}

# The session's totals, clamped.
#
# Waiting and away are disjoint intervals by construction, so their sum cannot
# exceed the elapsed total. A clock that moved backwards can still produce a
# figure that does, and a summary reporting more away time than session is
# worse than one that is slightly short, so the away figure absorbs it.
ct_session_totals() {
  local sid="${1:-}" base now elapsed
  _CT_START=0; _CT_TURNS=0; _CT_WAIT=0; _CT_IDLE=0
  base="$(ct_state_file "$sid")" || return 0
  _CT_START="$(ct_read_counter "${base}.start")"
  _CT_TURNS="$(ct_read_counter "${base}.turns")"
  _CT_WAIT="$(ct_read_counter "${base}.wait")"
  _CT_IDLE="$(ct_read_counter "${base}.idle")"

  [ "$_CT_START" -gt 0 ] || return 0
  now="$(date +%s)"
  elapsed=$(( now - _CT_START ))
  [ "$elapsed" -lt 0 ] && elapsed=0
  [ "$_CT_WAIT" -gt "$elapsed" ] && _CT_WAIT="$elapsed"
  [ "$(( _CT_WAIT + _CT_IDLE ))" -gt "$elapsed" ] && _CT_IDLE=$(( elapsed - _CT_WAIT ))
  return 0
}

# Remove every state file belonging to one session. Called at session end, so
# the state directory does not accumulate a file set per session forever.
ct_clear_state() {
  local base
  base="$(ct_state_file "${1:-}")" || return 0
  rm -f "$base" "$base".* 2>/dev/null
  return 0
}

# Drop state files from sessions that ended days ago. Called at session start.
ct_prune_state() {
  local dir
  dir="$(ct_state_dir)"
  [ -d "$dir" ] && find "$dir" -type f -mtime +7 -delete 2>/dev/null
  return 0
}
