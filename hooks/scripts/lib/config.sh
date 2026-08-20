#!/usr/bin/env bash
# Shared configuration for claude-timestamp.
#
# Sourced by every hook and by setup.sh. Defines the defaults, reads the user's
# config file, and provides the small render helpers the hooks need. Sourcing
# this file has no side effects beyond defining functions -- call ct_load_config
# to actually populate CT_* variables.
#
# The config file is parsed, never sourced. Sourcing would execute whatever
# happened to be in it; a whitelist reader costs the same ten lines and cannot
# run code. Unknown keys are ignored rather than being an error, so a config
# written by a newer version stays readable by an older one.

# Resolved when asked rather than when this file is sourced, so a caller that
# changes HOME afterwards gets the path it expects.
CT_CONFIG_NAME=".claude/claude-timestamp.conf"

# A project may carry its own settings, layered over the user's. The file has
# the same name and format, and only the keys it sets are overridden, so a
# repository can pin a timezone without restating everything else.
CT_PROJECT_CONFIG_NAME="$CT_CONFIG_NAME"

# Path to the active config file. CLAUDE_TIMESTAMP_CONFIG exists so the test
# suite can point at a temp file; it is not a user-facing setting.
ct_config_path() {
  printf '%s' "${CLAUDE_TIMESTAMP_CONFIG:-${HOME}/$CT_CONFIG_NAME}"
}

# Render a path with $HOME shortened to ~. Only affects what is printed; every
# path the scripts actually use stays absolute.
ct_tilde() {
  local path="${1:-}"
  if [ -n "${HOME:-}" ] && [ "${path#"$HOME"/}" != "$path" ]; then
    # shellcheck disable=SC2088  # the tilde is display text, not a path to expand
    printf '~/%s' "${path#"$HOME"/}"
  else
    printf '%s' "$path"
  fi
}

# Populate CT_* from defaults, then overlay whatever the config file sets.
# The CT_* variables set here are this library's public interface -- every
# consumer is a separate file, so shellcheck cannot see them being read.
# shellcheck disable=SC2034
# Find the project config covering a directory, by walking up from it.
#
# The search stops at $HOME, because the file directly under it is the user
# config rather than a project one. It also stops at the filesystem root, and
# after a bounded number of steps so a symlink loop cannot hang a hook.
ct_find_project_config() {
  local dir="${1:-}" steps=0
  [ -n "$dir" ] || return 1
  [ -d "$dir" ] || return 1
  dir="$(cd "$dir" 2>/dev/null && pwd)" || return 1

  while [ -n "$dir" ] && [ "$dir" != "/" ] && [ "$steps" -lt 40 ]; do
    if [ -n "${HOME:-}" ] && [ "$dir" = "$HOME" ]; then
      return 1
    fi
    if [ -r "$dir/$CT_PROJECT_CONFIG_NAME" ]; then
      printf '%s' "$dir/$CT_PROJECT_CONFIG_NAME"
      return 0
    fi
    dir="$(dirname "$dir")"
    steps=$((steps + 1))
  done
  return 1
}

# Read one config file over whatever is already loaded.
#
# Parsed against a list of known keys and never executed. Sourcing it would run
# whatever happened to be in the file; a whitelist reader costs the same ten
# lines and cannot. Unknown keys are ignored rather than being an error, so a
# file written by a newer version stays readable by an older one.
_ct_read_config_file() {
  local file="$1" line key value

  # `|| [ -n "$line" ]` so a final line with no trailing newline is still read.
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"                      # tolerate CRLF configs
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in *=*) ;; *) continue ;; esac

    key="${line%%=*}"
    value="${line#*=}"
    key="${key#"${key%%[![:space:]]*}"}";     key="${key%"${key##*[![:space:]]}"}"
    value="${value#"${value%%[![:space:]]*}"}"; value="${value%"${value##*[![:space:]]}"}"
    case "$value" in
      \"*\") value="${value#\"}"; value="${value%\"}" ;;
      \'*\') value="${value#\'}"; value="${value%\'}" ;;
    esac

    case "$key" in
      ENABLED)        CT_ENABLED="$value" ;;
      TZ)             CT_TZ="$value" ;;
      DISPLAY_FORMAT) CT_DISPLAY_FORMAT="$value" ;;
      CONTEXT_FORMAT) CT_CONTEXT_FORMAT="$value" ;;
      COLOR)          CT_COLOR="$value" ;;
      ELAPSED)        CT_ELAPSED="$value" ;;
      DATE_ROLLOVER)  CT_DATE_ROLLOVER="$value" ;;
      SLOW_AFTER)     CT_SLOW_AFTER="$value" ;;
      SLOW_COLOR)     CT_SLOW_COLOR="$value" ;;
      IDLE_AFTER)     CT_IDLE_AFTER="$value" ;;
      SUMMARY)        CT_SUMMARY="$value" ;;
      SUBAGENTS)      CT_SUBAGENTS="$value" ;;
      TOOL_TIMING)    CT_TOOL_TIMING="$value" ;;
      HISTORY)        CT_HISTORY="$value" ;;
      HISTORY_LIMIT)  CT_HISTORY_LIMIT="$value" ;;
      INJECT_CONTEXT) CT_INJECT_CONTEXT="$value" ;;
    esac
  done < "$file"
}

# The CT_* variables set here are this library's public interface -- every
# consumer is a separate file, so shellcheck cannot see them being read.
# shellcheck disable=SC2034
ct_load_config() {
  CT_ENABLED="on"             # master switch; off silences every hook
  CT_TZ=""                    # empty = machine local time
  CT_DISPLAY_FORMAT="24h"     # preset name or raw strftime
  CT_CONTEXT_FORMAT="24h"
  CT_COLOR="dim"
  CT_ELAPSED="on"
  CT_SLOW_AFTER="60"          # seconds; 0 disables
  CT_SLOW_COLOR="yellow"
  CT_IDLE_AFTER="3600"        # seconds; 0 disables
  CT_DATE_ROLLOVER="on"
  CT_SUMMARY="on"
  CT_SUBAGENTS="on"
  CT_TOOL_TIMING="off"        # adds two forks per tool call, so opt-in
  CT_HISTORY="on"
  CT_HISTORY_LIMIT="200"      # sessions kept; older ones are dropped
  CT_INJECT_CONTEXT="true"

  CT_CONFIG_PROBLEMS=""
  CT_PROJECT_CONFIG=""

  local file
  file="$(ct_config_path)"
  [ -r "$file" ] && _ct_read_config_file "$file"

  # The project layer goes on top, so a repository can pin one setting without
  # restating the rest. CLAUDE_TIMESTAMP_CONFIG is a test hook rather than a
  # user setting, so pointing it somewhere also disables the project layer:
  # a test asking for one exact file should get exactly that file.
  if [ -z "${CLAUDE_TIMESTAMP_CONFIG:-}" ]; then
    # Defaults to the working directory. The tool hooks rely on that: they
    # decide whether to do anything at all before reading their payload, so
    # they have no cwd to pass yet, and paying for a jq process per tool call
    # just to look one up would cost more than it is worth.
    local project
    if project="$(ct_find_project_config "${1:-${PWD:-}}")"; then
      CT_PROJECT_CONFIG="$project"
      _ct_read_config_file "$project"
    fi
  fi

  ct_validate_config
}

# Validators. These live here rather than in setup.sh because both the loader
# and the setup script need the same answer to "is this a usable value", and
# two copies of that question drift apart.
ct_is_valid_color()  { case "${1:-}" in none|off|dim|gray|grey|red|green|yellow|blue|magenta|cyan) return 0 ;; *) return 1 ;; esac; }
ct_is_valid_format() { case "${1:-}" in *%*|24h|short|12h|iso) return 0 ;; *) return 1 ;; esac; }
ct_is_seconds()      { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
ct_is_onoff()        { case "${1:-}" in on|off) return 0 ;; *) return 1 ;; esac; }
ct_is_bool()         { case "${1:-}" in true|false) return 0 ;; *) return 1 ;; esac; }

# A pinned zone is checked for shape here and for whether this platform can
# honour it separately, because those are different failures with different
# advice attached.
ct_is_valid_tz() {
  case "${1:-}" in
    '') return 0 ;;
    /*|*/../*|*/..) return 1 ;;
    *) return 0 ;;
  esac
}

# Replace one setting with its default when the configured value is unusable,
# and record why. Values come from a file a person edited, so a typo should say
# so rather than quietly doing nothing.
_ct_require() {
  local name="$1" check="$2" default="$3" var="CT_$1" value
  value="${!var}"
  "$check" "$value" && return 0
  printf -v "$var" '%s' "$default"
  CT_CONFIG_PROBLEMS="${CT_CONFIG_PROBLEMS}${CT_CONFIG_PROBLEMS:+$'\n'}  $name=$value is not valid, using $default"
}

# Check everything the config file can set. Reports through CT_CONFIG_PROBLEMS
# rather than printing, because the hooks that call this have no business
# writing to a user's screen on every message.
ct_validate_config() {
  CT_CONFIG_PROBLEMS=""
  _ct_require ENABLED        ct_is_onoff        on
  _ct_require TZ             ct_is_valid_tz     ""
  _ct_require DISPLAY_FORMAT ct_is_valid_format 24h
  _ct_require CONTEXT_FORMAT ct_is_valid_format 24h
  _ct_require COLOR          ct_is_valid_color  dim
  _ct_require SLOW_COLOR     ct_is_valid_color  yellow
  _ct_require SLOW_AFTER     ct_is_seconds      60
  _ct_require IDLE_AFTER     ct_is_seconds      3600
  _ct_require ELAPSED        ct_is_onoff        on
  _ct_require DATE_ROLLOVER  ct_is_onoff        on
  _ct_require SUMMARY        ct_is_onoff        on
  _ct_require SUBAGENTS      ct_is_onoff        on
  _ct_require TOOL_TIMING    ct_is_onoff        off
  _ct_require HISTORY        ct_is_onoff        on
  _ct_require HISTORY_LIMIT  ct_is_seconds      200
  _ct_require INJECT_CONTEXT ct_is_bool         true
}

# Preset name -> strftime string. Anything containing a % is already a strftime
# string and passes through untouched, so raw formats need no separate setting.
ct_expand_format() {
  case "$1" in
    *%*)   printf '%s' "$1" ;;
    short) printf '%s' '%H:%M' ;;
    12h)   printf '%s' '%I:%M %p' ;;
    iso)   printf '%s' '%Y-%m-%dT%H:%M:%S' ;;
    24h|*) printf '%s' '%H:%M:%S' ;;
  esac
}

# Whether this platform can resolve IANA zone names at all. Git Bash on Windows
# ships without a zoneinfo database, and date then silently falls back to UTC
# for any name it cannot resolve -- so a pinned zone renders the wrong time
# rather than failing loudly. Asia/Tokyo is the probe because it is never at
# UTC, which makes the check independent of whichever zone the user picked.
# Memoised, so a process pays for at most one extra `date` call.
ct_tz_supported() {
  if [ -z "${CT_TZ_SUPPORTED:-}" ]; then
    if [ "$(TZ=Asia/Tokyo date +%z 2>/dev/null)" = "+0000" ]; then
      CT_TZ_SUPPORTED=no
    else
      CT_TZ_SUPPORTED=yes
    fi
  fi
  [ "$CT_TZ_SUPPORTED" = "yes" ]
}

# Whether the pinned zone can actually be honoured here. UTC and GMT are plain
# POSIX zone strings that date understands with no database at all, so they
# work everywhere; only IANA names such as Asia/Tokyo need one.
ct_tz_honoured() {
  [ -n "${CT_TZ:-}" ] || return 1
  case "$CT_TZ" in UTC|GMT) return 0 ;; esac
  ct_tz_supported
}

# True when a zone is pinned that this platform cannot honour.
ct_tz_unhonoured() {
  [ -n "${CT_TZ:-}" ] && ! ct_tz_honoured
}

# Render the current time in the given format. CT_TZ is applied per-call rather
# than exported, so one process can render display and context in one timezone
# without leaking TZ into anything else it runs.
ct_now() {
  local fmt out
  fmt="$(ct_expand_format "$1")"
  # A pinned zone this platform cannot resolve is ignored: local time is merely
  # not what was asked for, whereas UTC-pretending-to-be-Tokyo is wrong.
  if ct_tz_honoured; then
    out="$(TZ="$CT_TZ" date "+$fmt")"
  else
    out="$(date "+$fmt")"
  fi
  # %I is zero-padded and BSD date has no %-I, so trim the pad by hand.
  [ "$1" = "12h" ] && out="${out#0}"
  printf '%s' "$out"
}

# Current timezone abbreviation (CEST, JST...) for the model-facing string.
ct_zone() {
  if ct_tz_honoured; then TZ="$CT_TZ" date '+%Z'; else date '+%Z'; fi
}

ct_color_start() {
  # https://no-color.org -- any non-empty value disables color.
  [ -n "${NO_COLOR:-}" ] && return 0
  case "$1" in
    dim)       printf '%s' $'\033[2m' ;;
    gray|grey) printf '%s' $'\033[90m' ;;
    red)       printf '%s' $'\033[31m' ;;
    green)     printf '%s' $'\033[32m' ;;
    yellow)    printf '%s' $'\033[33m' ;;
    blue)      printf '%s' $'\033[34m' ;;
    magenta)   printf '%s' $'\033[35m' ;;
    cyan)      printf '%s' $'\033[36m' ;;
    *)         printf '' ;;
  esac
}

ct_color_end() {
  [ -n "$(ct_color_start "$1")" ] && printf '%s' $'\033[0m'
  return 0
}

ct_is_color() { [ -n "$(ct_color_start "$1")" ]; }

# Wrap text in a color, or return it untouched when that color is off. Keeps
# callers from having to pair start and end themselves.
ct_paint() {
  local color="$1" text="$2" start
  start="$(ct_color_start "$color")"
  if [ -n "$start" ]; then
    printf '%s%s%s' "$start" "$text" "$(ct_color_end "$color")"
  else
    printf '%s' "$text"
  fi
}

# The clock used for tool timings. EPOCHREALTIME gives sub-second precision but
# is bash 5+, and macOS still ships bash 3.2 as /bin/bash while BSD date has no
# %N -- so there is no portable sub-second fallback. Whole seconds it is, and
# the call counts carry the signal where durations round to zero.
ct_now_precise() {
  if [ -n "${EPOCHREALTIME:-}" ]; then
    # Some locales render EPOCHREALTIME with a comma.
    printf '%s' "${EPOCHREALTIME/,/.}"
  else
    date +%s
  fi
}

# Difference between two ct_now_precise readings, to one decimal. Uses awk
# because the shell cannot do decimal arithmetic. A negative result means the
# clock moved backwards mid-call and is reported as zero.
ct_duration_between() {
  awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN { d = b - a; if (d < 0) d = 0; printf "%.3f", d }'
}

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

# Where one in-flight tool call's start time is parked. Keyed by tool_use_id
# rather than tool name because Claude Code runs tool calls in parallel, so
# name-keyed state would interleave between concurrent calls of the same tool.
ct_tool_state_file() {
  local base tuid
  base="$(ct_state_file "${1:-}")" || return 1
  tuid="$(printf '%s' "${2:-}" | tr -cd 'A-Za-z0-9_-')"
  [ -n "$tuid" ] || return 1
  printf '%s.tool.%s' "$base" "$tuid"
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
      if (best == "" || top * 2 < total) exit 1
      if (top < 60) printf "%s %ds", best, int(top + 0.5)
      else          printf "%s %dm%02ds", best, int(top / 60), int(top) % 60
    }' "$log"
}

# Seconds -> 45s / 2m14s / 1h03m. Refuses anything that is not a whole number,
# which also covers a clock that moved backwards.
ct_format_duration() {
  local s="${1:-}"
  case "$s" in ''|*[!0-9]*) return 1 ;; esac
  if   [ "$s" -lt 60 ];   then printf '%ds' "$s"
  elif [ "$s" -lt 3600 ]; then printf '%dm%02ds' "$((s / 60))" "$((s % 60))"
  else                         printf '%dh%02dm' "$((s / 3600))" "$(((s % 3600) / 60))"
  fi
}

# The same duration as a turn marker: +45s / +2m14s / +1h03m.
ct_format_elapsed() {
  local d
  d="$(ct_format_duration "${1:-}")" || return 1
  printf '+%s' "$d"
}

# A coarser rendering for the idle divider, where "2h" reads better than
# "2h07m" -- the point is that you were away, not exactly how long.
ct_humanize_gap() {
  local s="${1:-}"
  case "$s" in ''|*[!0-9]*) return 1 ;; esac
  if   [ "$s" -lt 5400 ];   then printf '%dm' "$((s / 60))"
  elif [ "$s" -lt 129600 ]; then printf '%dh' "$((s / 3600))"
  else                           printf '%dd' "$((s / 86400))"
  fi
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

# Remove every state file belonging to one session. Called at session end, so
# the state directory does not accumulate a file set per session forever.
ct_clear_state() {
  local base
  base="$(ct_state_file "${1:-}")" || return 0
  rm -f "$base" "$base".* 2>/dev/null
  return 0
}

# Where finished sessions are recorded. Unlike the per-session state this
# outlives the session, so it lives beside the config rather than in a
# temporary directory.
#
# Timing only: no message text, no tool arguments, and no paths. There is
# nothing in here that says what you were working on, which keeps a file that
# accumulates indefinitely from becoming something you would rather it were
# not.
ct_history_path() {
  printf '%s' "${CLAUDE_TIMESTAMP_HISTORY:-${HOME}/.claude/claude-timestamp-history.tsv}"
}

# Machine-level facts, published for whoever configures the plugin from inside
# Claude Code so they need no subprocess to learn them. Only things that cannot
# be read out of the config files belong here: the effective settings do not,
# because they would be stale the moment the config is edited, and the project
# config path does not, because it depends on a working directory that differs
# between concurrent sessions.
#
# CLAUDE_TIMESTAMP_FACTS exists so the test suite can point at a temp file; it
# is not a user-facing setting.
ct_facts_path() {
  printf '%s' "${CLAUDE_TIMESTAMP_FACTS:-${HOME}/.claude/claude-timestamp.facts.json}"
}

# Append one finished session and drop anything past the retention limit.
# Fields: when, seconds, turns, waited, idle, failed tools.
ct_history_append() {
  local file limit tmp
  file="$(ct_history_path)"
  mkdir -p "$(dirname "$file")" 2>/dev/null || return 0

  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date '+%Y-%m-%dT%H:%M:%S')" "${1:-0}" "${2:-0}" "${3:-0}" "${4:-0}" "${5:-0}" >> "$file" 2>/dev/null || return 0

  limit="${CT_HISTORY_LIMIT:-200}"
  case "$limit" in ''|*[!0-9]*) limit=200 ;; esac
  [ "$limit" -lt 1 ] && limit=1

  # Rewrite only when the file has actually outgrown the limit, so the common
  # case is a plain append.
  if [ "$(wc -l < "$file" 2>/dev/null || echo 0)" -gt "$limit" ]; then
    tmp="$file.$$"
    if tail -n "$limit" "$file" > "$tmp" 2>/dev/null; then
      mv "$tmp" "$file" 2>/dev/null || rm -f "$tmp"
    else
      rm -f "$tmp"
    fi
  fi
  return 0
}

# Drop state files from sessions that ended days ago. Called at session start.
ct_prune_state() {
  local dir
  dir="$(ct_state_dir)"
  [ -d "$dir" ] && find "$dir" -type f -mtime +7 -delete 2>/dev/null
  return 0
}
