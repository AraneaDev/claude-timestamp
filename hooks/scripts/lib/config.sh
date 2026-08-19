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

CT_CONFIG_DEFAULT="${HOME}/.claude/claude-timestamp.conf"

# Path to the active config file. CLAUDE_TIMESTAMP_CONFIG exists so the test
# suite can point at a temp file; it is not a user-facing setting.
ct_config_path() {
  printf '%s' "${CLAUDE_TIMESTAMP_CONFIG:-$CT_CONFIG_DEFAULT}"
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
ct_load_config() {
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
  CT_INJECT_CONTEXT="true"

  local file line key value
  file="$(ct_config_path)"
  [ -r "$file" ] || return 0

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
      INJECT_CONTEXT) CT_INJECT_CONTEXT="$value" ;;
    esac
  done < "$file"
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

# Drop state files from sessions that ended days ago. Called at session start.
ct_prune_state() {
  local dir
  dir="$(ct_state_dir)"
  [ -d "$dir" ] && find "$dir" -type f -mtime +7 -delete 2>/dev/null
  return 0
}
