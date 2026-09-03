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

# Where per-session state lives.
#
# Per-user, because ${TMPDIR:-/tmp} is shared ground on a multi-user machine
# and this directory used to be one fixed name in it. Whoever created it first
# owned it: for the next user it was either unwritable, silently disabling
# elapsed time and the summary, or -- if created world-writable -- a place to
# pre-plant a symlink under a filename the plugin would then open for writing.
#
# Assign the state directory into _CT_STATE_DIR, without forking.
#
# ct_state_dir prints, which means a command substitution, which means a
# subshell. That is fine on a path that runs once per message and wrong on one
# that runs once per tool call. Same assign-don't-print reasoning as
# ct_color_seq and ct_paint_part, for the same reason: a fork on a hot path.
#
# $UID is a bash builtin and matches `id -u`, so the uid costs nothing either.
ct_state_dir_var() {
  _CT_STATE_DIR="${TMPDIR:-/tmp}/claude-timestamp-${UID:-0}"
}

ct_state_dir() { ct_state_dir_var; printf '%s' "$_CT_STATE_DIR"; }

# Make sure the state directory exists, belongs to us, and is private.
#
# Returns 1 rather than repairing anything about who owns it: a directory of
# this name owned by somebody else is a situation to decline, not to take
# over. Callers treat a failure the way they already treat an unwritable
# directory, which is to do less rather than to fail.
ct_state_ready() {
  local dir line perms

  # Resolve without a subshell: ct_state_dir() prints, and a print costs a fork
  # at every call site. The _var form assigns, which is the pattern
  # ct_paint_part and ct_color_seq already established for the hot paths.
  ct_state_dir_var
  dir="$_CT_STATE_DIR"

  # Refuse a symlink outright, before any test that would follow one.
  #
  # This line is load-bearing and easy to delete by accident, so: `[ -d ]`,
  # `[ -O ]` and `chmod` all FOLLOW symlinks. `ls -ld` does not. Without this
  # check, an attacker who plants a symlink at this path pointing at a
  # directory we DO own passes an ownership test that follows it, and then the
  # mode branch below chmods their chosen target rather than our state
  # directory. Measured, on a build that lacked this line: a victim directory
  # went from mode 755 to 700 at the attacker's choosing.
  #
  # Refusing every symlink is also stricter than checking who owns it. A
  # symlink here that we own ourselves is still a path we did not create and
  # cannot vouch for, and declining costs the user nothing but a session
  # without timings.
  if [ -L "$dir" ]; then
    return 1
  fi

  # Two paths, and the split is what keeps this both safe and cheap.
  #
  # The hazard is a directory of this name that somebody else planted. `mkdir
  # -p` is no defence, because it succeeds on an existing directory no matter
  # who owns it -- so a function that tested `[ ! -d ]` and then created would
  # return success having never looked at what was there. The defence is that
  # EVERY path which finds an existing directory inspects it, and the only path
  # that creates one uses plain `mkdir -m 700`, which is atomic and fails if
  # anyone won the race. Neither branch can reach `return 0` on a directory it
  # has not either created privately itself or inspected below.
  #
  # /tmp is swept periodically on many systems, so the directory can vanish
  # under a live session. Nothing here is cached for that reason: this runs in
  # full on every call, and the steady state costs exactly one process. A sweep
  # landing mid-call makes this return 1 rather than rebuilding, which costs
  # one message its timings; the next call finds nothing there and creates it.
  if [ ! -d "$dir" ]; then
    mkdir -p "${dir%/*}" 2>/dev/null || true
    mkdir -m 700 "$dir" 2>/dev/null && return 0
    # Lost the race, or could not create it. Fall through and inspect.
    [ -d "$dir" ] || return 1
    # Whoever won the race may have won it with a symlink.
    if [ -L "$dir" ]; then
      return 1
    fi
  fi

  # `[ -O ]` is a bash builtin comparing the EFFECTIVE UID numerically. It
  # costs no process, and it is stricter than matching `ls`'s owner column
  # against `id -un`: ls truncates a long owner name on some systems, and two
  # account names can map to one uid. It is only safe here because the symlink
  # rejection above has already run.
  [ -O "$dir" ] || return 1

  # Ownership alone was never the guarantee. A directory we own but that anyone
  # can write to lets any local user create a symlink inside it, which is the
  # original attack with one extra step. Tighten rather than decline: the
  # directory is ours, so repairing it is both safe and what the user wants.
  # This is the one process the steady state pays, and it is not cached --
  # a mode can be loosened after we last looked, including by our own hand.
  # shellcheck disable=SC2012  # ls -ld reads the mode; find -printf is GNU-only
  line="$(ls -ld "$dir" 2>/dev/null)" || return 1
  perms="${line%% *}"
  case "$perms" in
    drwx------*) ;;
    # The leading `d` is load-bearing, not decoration. `ls -ld` is the one
    # thing here that does NOT follow a symlink, so a `l` in this position
    # means the entry was swapped for a symlink after the [ -L ] guard above
    # ran -- and `chmod` DOES follow, so the arm below would tighten whatever
    # the attacker pointed at instead of our own directory. Refuse rather than
    # repair anything whose type we did not just confirm.
    d*) chmod 700 "$dir" 2>/dev/null || return 1 ;;
    *) return 1 ;;
  esac

  [ -w "$dir" ] || return 1
  return 0
}

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
    # A line is only counted when it is whole. The writer appends while this
    # runs, so the last line can be a fragment, and a fragment summed as a
    # tool name would put the wrong name on a marker.
    NF == 3 && $2 ~ /^[0-9]+\.[0-9][0-9][0-9]$/ { sum[$1] += $2 }
    END {
      best = ""; top = 0
      for (t in sum) if (sum[t] > top) { top = sum[t]; best = t }
      if (top > total) top = total
      if (best == "" || top * 2 < total) exit 1
      if (top < 60) printf "%s %ds", best, int(top + 0.5)
      else          printf "%s %dm%02ds", best, int(top / 60), int(top) % 60
    }' "$log"
}

# Does any session on this machine want tool timing?
#
# The gate post-tool-use.sh opens with, lifted out of it so it can be tested
# directly: the hook's own output is identical whether this says yes or no, so
# the only thing an end-to-end test could observe is the cost, which is the
# whole point of the gate.
#
# Answered with a glob before anything forks. This runs on every tool call, and
# the README promises TOOL_TIMING is the only setting that costs anything at
# that rate. Learning the session id needs jq, and forking jq to discover there
# was nothing to do would make every user running the default pay for a feature
# they have switched off. A sentinel is staged per session while tool timing is
# on, so no match here means no session wants timing and the hook is finished.
# A match means SOME session does; which one still needs the payload, and that
# is where the fork earns its place.
#
# Conservative on purpose: one session with timing on makes every concurrent
# session pay the parse. Over-recording is recoverable, a missed measurement is
# not.
ct_timing_wanted() {
  local f matched=1
  ct_state_dir_var

  for f in "$_CT_STATE_DIR"/*.timing-on; do
    [ -e "$f" ] && matched=0
    break
  done

  if [ "$matched" -eq 0 ]; then
    # A sentinel is re-staged by every prompt, and a tool call always follows a
    # prompt in the same turn, so one untouched for a day belongs to a session
    # that ended without a SessionEnd: a crash, a killed terminal, a machine
    # that slept. Nothing else clears it, and ct_prune_state does not come back
    # for a week -- so without this, one dead session taxes every tool call in
    # every OTHER session on the machine with the parse this gate exists to
    # avoid, for seven days.
    #
    # The fork is only reached once the glob has already said yes, which is the
    # path that was going to fork jq anyway. A miss still costs nothing at all.
    # No pipe: `find | head` would take SIGPIPE and report 141 under pipefail.
    if [ -n "$(find "$_CT_STATE_DIR" -maxdepth 1 -name '*.timing-on' -mmin -1440 2>/dev/null)" ]; then
      return 0
    fi
  fi

  # A session whose first prompt predates the staged flag has a turn file but
  # never staged an .enabled sibling, so it cannot appear in the glob above --
  # it has no way to say what it wants. Rather than let the gate answer "no
  # session wants timing" on its behalf, its calls fall through to the same jq
  # parse and config resolution every call used to pay, until its next prompt
  # catches it up and stages a real answer.
  #
  # This scan's cost grows with the number of sessions in state (measured: ~5ms
  # at 1, ~9ms at 100, ~18ms at 300, bounded by the 7-day prune) -- kept anyway.
  # A missed tool-call measurement is an accuracy loss in the exact number this
  # feature exists to produce; a few extra milliseconds of hook overhead on an
  # already-cheap path is not something this plugin is optimising away.
  for f in "$_CT_STATE_DIR"/*; do
    # Match the ENTRY name, not the whole path. $f is absolute, and a $TMPDIR
    # with a dot anywhere in it -- macOS hands out /var/folders/xy/....../T by
    # default -- makes `*.*` match every entry, so the scan skips every session
    # and tool timing never turns on for a session that predates the staged
    # flag.
    case "${f##*/}" in
      *.*) continue ;;
    esac
    [ -e "$f" ] || continue
    [ -e "${f}.enabled" ] || return 0
  done

  return 1
}

# Stage a decision the tool hooks need but cannot make for themselves.
#
# PostToolUse decides whether to do anything before it parses its payload, so
# it has no cwd to resolve a project config from, and paying for a jq process
# per tool call to look one up would cost more than the feature. The prompt
# hook does have the payload's cwd, and runs once per turn, so it resolves the
# answer there and leaves it where the tool hook can read it with a builtin.
#
# Not the facts file: that is per-machine, so two sessions in different
# projects would overwrite each other's answer.
ct_stage_flag() {
  local sid="${1:-}" name="${2:-}" value="${3:-}" base
  [ -n "$name" ] || return 0
  base="$(ct_state_file "$sid")" || return 0
  ct_state_ready || return 0
  printf '%s' "$value" > "${base}.${name}"
  return 0
}

ct_read_flag() {
  local sid="${1:-}" name="${2:-}" base
  [ -n "$name" ] || return 0
  base="$(ct_state_file "$sid")" || return 0
  [ -r "${base}.${name}" ] || return 0
  cat "${base}.${name}" 2>/dev/null
  return 0
}

ct_clear_flag() {
  local sid="${1:-}" name="${2:-}" base
  [ -n "$name" ] || return 0
  base="$(ct_state_file "$sid")" || return 0
  rm -f "${base}.${name}" 2>/dev/null || true
  return 0
}

# Read a counter from the session state, defaulting to 0 when absent or
# corrupt, so a damaged state file degrades to "no history" rather than
# breaking the marker.
#
# `read` rather than `cat`: this runs several times per stamped message, and a
# builtin costs no process.
ct_read_counter() {
  local file="$1" value=""
  [ -r "$file" ] || { printf '0'; return 0; }
  # Not `read ... || value=""`: state files are written with `printf '%s'`,
  # with no trailing newline, and `read` reports that as failure even though
  # it has already assigned the value. Gating on the exit status would throw
  # away a perfectly good read on the file shape this codebase actually
  # writes. The empty-file case is still covered -- value keeps its `local`
  # initial "" when there is nothing to read.
  #
  # `|| :` discards that status without touching the value, and it is
  # load-bearing rather than decoration. Every caller runs under the hooks'
  # `set -euo pipefail`, where a failing simple command aborts the script. The
  # only thing that has ever stopped this line from doing that is bash
  # clearing errexit inside a command substitution -- which every call site
  # happens to be. That default is not ours to rely on: BASHOPTS carries
  # inherit_errexit in from the environment, one `shopt` turns it on, and a
  # caller that reads a counter as a plain statement never had the protection
  # at all. Without this, all three cases kill the hook at its first state
  # read and the plugin goes silent with nothing reported.
  IFS= read -r value < "$file" 2>/dev/null || :
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
  else
    # ...but it is not closed at that earlier time. The end passed in here is
    # the last message drawn on screen, and a turn that drew nothing at all --
    # straight into a long tool call, then an interrupt -- leaves that pointing
    # at the PREVIOUS turn. ct_record_away measures the user's break from
    # .closed, so stamping it with a time before this turn even opened hands
    # the gap this turn's entire duration on top of the real break: twenty
    # minutes spent watching a build, reported as twenty minutes away.
    #
    # The turn still contributes no waiting time, because none was observed.
    # Closing at its own start is simply the earliest moment that was
    # certainly not a gap.
    ended="$started"
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
  local sid="${1:-}" now="${2:-0}" base start
  base="$(ct_state_file "$sid")" || return 0
  case "$now" in ''|*[!0-9]*) return 0 ;; esac
  ct_state_ready || return 0

  printf '%s' "$now" > "$base"
  rm -f "${base}.closed" 2>/dev/null || true

  # Rewritten on every prompt rather than only when absent, so its modification
  # time tracks the session. ct_prune_state deletes by mtime, and this was the
  # one state file written once and never touched again: a session left open
  # longer than the prune window lost it while still running, _CT_START then
  # read 0, and session-end skipped both the summary and the history row. The
  # longest session on the machine was the one that went unrecorded.
  #
  # The value is preserved -- only the timestamp on the file is refreshed. Read
  # with the builtin rather than through ct_read_counter, which answers 0 for
  # an absent file and would quietly reset a real start time to the epoch.
  start=""
  if [ -r "${base}.start" ]; then
    IFS= read -r start < "${base}.start" 2>/dev/null || :
  fi
  case "$start" in ''|*[!0-9]*) start="$now" ;; esac
  printf '%s' "$start" > "${base}.start"

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

  # Clear first, unconditionally, so that every path through this function
  # positively decides what `.away` holds. Leaving the early returns silent
  # would let a staged figure outlive the boundary it belongs to: a turn that
  # closes after a real break but then renders no message -- a tool-only turn,
  # or one interrupted before any text streamed -- leaves its gap staged, and
  # the next boundary, if it does not itself qualify, would leave that stale
  # figure in place for whichever message renders next. That message would draw
  # a divider for a break that never happened, and the model would be told the
  # same thing.
  rm -f "${base}.away" 2>/dev/null || true

  case "$now" in ''|*[!0-9]*) return 0 ;; esac
  [ "${CT_IDLE_AFTER:-0}" -gt 0 ] 2>/dev/null || return 0

  closed="$(ct_read_counter "${base}.closed")"
  [ "$closed" -gt 0 ] || return 0
  gap=$(( now - closed ))
  [ "$gap" -ge "$CT_IDLE_AFTER" ] || return 0

  ct_state_ready || return 0
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
  ct_state_ready || return 0
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
#
# The legacy shared directory is swept too, for one release: state written
# before the per-user move is orphaned rather than migrated, because a session
# already running keeps its own path until it restarts. Remove this once no
# supported version writes there.
ct_prune_state() {
  local dir legacy
  dir="$(ct_state_dir)"
  [ -d "$dir" ] && find "$dir" -type f -mtime +7 -delete 2>/dev/null
  legacy="${TMPDIR:-/tmp}/claude-timestamp"
  if [ -d "$legacy" ] && [ ! -L "$legacy" ]; then
    find "$legacy" -maxdepth 1 -type f -mtime +7 -delete 2>/dev/null
  fi
  return 0
}
