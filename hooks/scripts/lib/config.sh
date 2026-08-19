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
  CT_DATE_ROLLOVER="on"
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

# True when a zone is pinned that this platform cannot honour.
ct_tz_unhonoured() {
  [ -n "${CT_TZ:-}" ] && ! ct_tz_supported
}

# Render the current time in the given format. CT_TZ is applied per-call rather
# than exported, so one process can render display and context in one timezone
# without leaking TZ into anything else it runs.
ct_now() {
  local fmt out
  fmt="$(ct_expand_format "$1")"
  # A pinned zone this platform cannot resolve is ignored: local time is merely
  # not what was asked for, whereas UTC-pretending-to-be-Tokyo is wrong.
  if [ -n "${CT_TZ:-}" ] && ct_tz_supported; then
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
  if [ -n "${CT_TZ:-}" ] && ct_tz_supported; then TZ="$CT_TZ" date '+%Z'; else date '+%Z'; fi
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

# Seconds -> +45s / +2m14s / +1h03m. Refuses negative input (clock moved back).
ct_format_elapsed() {
  local s="${1:-}"
  case "$s" in ''|*[!0-9]*) return 1 ;; esac
  if   [ "$s" -lt 60 ];   then printf '+%ds' "$s"
  elif [ "$s" -lt 3600 ]; then printf '+%dm%02ds' "$((s / 60))" "$((s % 60))"
  else                         printf '+%dh%02dm' "$((s / 3600))" "$(((s % 3600) / 60))"
  fi
}

# Drop state files from sessions that ended days ago. Called at session start.
ct_prune_state() {
  local dir
  dir="$(ct_state_dir)"
  [ -d "$dir" ] && find "$dir" -type f -mtime +7 -delete 2>/dev/null
  return 0
}
