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
