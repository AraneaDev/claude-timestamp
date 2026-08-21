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
      MARKER)         CT_MARKER_TEMPLATE="$value" ;;
      TIME_COLOR)     CT_TIME_COLOR="$value" ;;
      ELAPSED_COLOR)  CT_ELAPSED_COLOR="$value" ;;
      TOOL_COLOR)     CT_TOOL_COLOR="$value" ;;
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
  CT_MARKER_TEMPLATE='[{%date }%time{ %elapsed}{ · %tool}]'
  CT_TIME_COLOR=""            # empty = inherit COLOR
  CT_ELAPSED_COLOR=""
  CT_TOOL_COLOR=""
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

# A part colour may be empty, which means inherit COLOR. Every other value is a
# colour name, so this is ct_is_valid_color plus the empty string.
ct_is_valid_part_color() { [ -z "${1:-}" ] && return 0; ct_is_valid_color "${1:-}"; }

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
  local check="$2" default="$3" shown="${4:-$1}" var="CT_$1" value
  value="${!var}"
  "$check" "$value" && return 0
  printf -v "$var" '%s' "$default"
  CT_CONFIG_PROBLEMS="${CT_CONFIG_PROBLEMS}${CT_CONFIG_PROBLEMS:+$'\n'}  $shown=$value is not valid, using $default"
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
  _ct_require MARKER_TEMPLATE ct_is_valid_marker '[{%date }%time{ %elapsed}{ · %tool}]' MARKER
  _ct_require TIME_COLOR      ct_is_valid_part_color  ""
  _ct_require ELAPSED_COLOR   ct_is_valid_part_color  ""
  _ct_require TOOL_COLOR      ct_is_valid_part_color  ""
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

# The escape sequence for a colour, assigned rather than printed so a caller on
# the hot path pays no subshell. Sets _CT_SEQ, which is empty when the colour is
# off, unknown, or disabled by NO_COLOR.
ct_color_seq() {
  _CT_SEQ=""
  # https://no-color.org -- any non-empty value disables color. Checked before
  # FORCE_COLOR, which is deliberately the opposite of the common convention
  # (chalk and similar give FORCE_COLOR priority): the README promises NO_COLOR
  # disables colour regardless of everything else, and demoting it here would
  # quietly break that documented guarantee.
  [ -n "${NO_COLOR:-}" ] && return 0
  if [ -z "${FORCE_COLOR:-}" ]; then
    # Escape codes only help where something interprets them. Claude Code sets
    # CLAUDE_CODE_ENTRYPOINT and a hook inherits it as any child process would;
    # "cli" is a real terminal, so it is the only value that earns colour
    # here. Unset also earns colour: an older Claude Code that predates this
    # variable, or setup.sh run directly as `bash setup.sh`, must not lose
    # colour on upgrade or in the wizard. Every other value, including ones
    # that do not exist yet (claude-vscode, claude-desktop, sdk-*, bench,
    # remote, ...), gets plain text -- colour missing where it might have
    # worked is the safe failure, not escape codes on every message.
    case "${CLAUDE_CODE_ENTRYPOINT-cli}" in
      cli) : ;;
      *) return 0 ;;
    esac
  fi
  case "${1:-}" in
    dim)       _CT_SEQ=$'\033[2m' ;;
    gray|grey) _CT_SEQ=$'\033[90m' ;;
    red)       _CT_SEQ=$'\033[31m' ;;
    green)     _CT_SEQ=$'\033[32m' ;;
    yellow)    _CT_SEQ=$'\033[33m' ;;
    blue)      _CT_SEQ=$'\033[34m' ;;
    magenta)   _CT_SEQ=$'\033[35m' ;;
    cyan)      _CT_SEQ=$'\033[36m' ;;
  esac
  return 0
}

ct_color_start() {
  ct_color_seq "${1:-}"
  printf '%s' "$_CT_SEQ"
}

# Paint one part of the marker and restore the base colour afterwards, so the
# literal text around it keeps its own styling.
#
# An empty part stays empty rather than becoming a bare escape sequence. The
# renderer decides whether a part is present by testing whether it is empty, and
# a lone colour code would read as present and leave its separator behind.
ct_paint_part() {
  local color="${1:-}" text="${2:-}" base="${3:-}"
  local seq base_seq
  _CT_PART=""
  [ -n "$text" ] || return 0
  ct_color_seq "$color"; seq="$_CT_SEQ"
  ct_color_seq "$base";  base_seq="$_CT_SEQ"
  if [ -n "$seq" ]; then
    _CT_PART="${seq}${text}"$'\033[0m'"${base_seq}"
  else
    _CT_PART="$text"
  fi
  return 0
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

# --- marker templates -------------------------------------------------------
#
# MARKER is a layout: literal text, four placeholders, and groups. A group is
# {...} containing at least one placeholder, and it renders as nothing when
# every placeholder inside it is empty. Groups exist because no automatic rule
# works: dropping the text before an empty part handles "[%time %elapsed]" and
# breaks "%time (%elapsed)", leaving a stray bracket, and dropping the text on
# both sides breaks the first instead. The template cannot tell decoration from
# structure, so the author says which is which.
#
# Everything here is a pure function of its arguments. No config, no clock, no
# filesystem, and no forks: this runs on every stamped message, and the wizard
# and doctor draw their previews with the same code, which is what keeps a
# preview from drifting away from the real marker.

# Read the placeholder starting at index $2 of $1, which is a '%'.
#
# Sets _CT_W to the name and _CT_WLEN to the characters consumed including the
# '%'. Returns 0 for a known placeholder, 1 for an unknown word, and 2 for a
# bare '%' that begins no word at all. The caller renders 1 and 2 as literal
# text; only the validator treats 1 as an error.
#
# The whole run of letters must match, so %timex is unknown rather than %time
# followed by an x. A placeholder that silently absorbed the text after it would
# be the harder bug to find.
_ct_word() {
  local s="$1"
  local i="$2" n j w
  n=${#s}
  j=$(( i + 1 ))
  while [ "$j" -lt "$n" ]; do
    case "${s:j:1}" in
      [[:alpha:]]) j=$(( j + 1 )) ;;
      *) break ;;
    esac
  done
  w="${s:i+1:j-i-1}"
  case "$w" in
    time|elapsed|tool|date) _CT_W="$w"; _CT_WLEN=$(( j - i )); return 0 ;;
    '') return 2 ;;
    *) return 1 ;;
  esac
}

# The value of a placeholder, from the four parts the caller passed in.
_ct_part() {
  case "$1" in
    time)    _CT_V="$_CT_P_TIME" ;;
    elapsed) _CT_V="$_CT_P_ELAPSED" ;;
    tool)    _CT_V="$_CT_P_TOOL" ;;
    date)    _CT_V="$_CT_P_DATE" ;;
    *)       _CT_V="" ;;
  esac
  return 0
}

# Render a span containing no braces, into _CT_SPAN.
#
# An empty placeholder consumes one run of spaces: the run before it, or the run
# after it when there is nothing before. One run either way, never both, so
# "%time  %elapsed" collapses to the clock alone rather than to a trailing
# space.
_ct_span() {
  local s="$1"
  local i=0 n out ch pending val swallow rc
  n=${#s}; out=""; pending=""; swallow=0
  while [ "$i" -lt "$n" ]; do
    ch="${s:i:1}"
    if [ "$ch" = "%" ]; then
      rc=0; _ct_word "$s" "$i" || rc=$?
      if [ "$rc" -eq 0 ]; then
        _ct_part "$_CT_W"; val="$_CT_V"
        if [ -n "$val" ]; then
          out="$out$pending$val"; pending=""; swallow=0
        elif [ -n "$pending" ]; then
          pending=""
        else
          swallow=1
        fi
        i=$(( i + _CT_WLEN ))
        continue
      fi
      # Unknown word or bare percent: literal text.
      swallow=0; out="$out$pending$ch"; pending=""; i=$(( i + 1 ))
    elif [ "$ch" = " " ]; then
      if [ "$swallow" -eq 1 ]; then i=$(( i + 1 )); continue; fi
      pending="$pending$ch"; i=$(( i + 1 ))
    else
      swallow=0; out="$out$pending$ch"; pending=""; i=$(( i + 1 ))
    fi
  done
  _CT_SPAN="$out$pending"
  return 0
}

# Whether a span contains at least one placeholder.
_ct_has_ph() {
  local s="$1"
  local i=0 n
  n=${#s}
  while [ "$i" -lt "$n" ]; do
    if [ "${s:i:1}" = "%" ] && _ct_word "$s" "$i"; then return 0; fi
    i=$(( i + 1 ))
  done
  return 1
}

# Whether a span holds at least one placeholder and every one of them is empty.
_ct_all_empty() {
  local s="$1"
  local i=0 n found
  n=${#s}; found=0
  while [ "$i" -lt "$n" ]; do
    if [ "${s:i:1}" = "%" ] && _ct_word "$s" "$i"; then
      found=1
      _ct_part "$_CT_W"
      [ -n "$_CT_V" ] && return 1
      i=$(( i + _CT_WLEN ))
    else
      i=$(( i + 1 ))
    fi
  done
  [ "$found" -eq 1 ]
}

# Render TEMPLATE with the four parts, into CT_MARKER.
#
# The parts arrive already painted, so this function knows nothing about colour;
# an absent part is the empty string, which is how a group learns it should
# vanish. It assigns rather than printing, because message-display.sh writes
# JSON to stdout and a helper that printed would corrupt the hook's output.
#
# CT_MARKER is this library's public interface -- nothing in this file reads
# it yet, since the caller that will (task 4) does not exist.
ct_render_marker() {
  local tpl="${1:-}"
  local out i n depth j grp k
  _CT_P_TIME="${2:-}"; _CT_P_ELAPSED="${3:-}"
  _CT_P_TOOL="${4:-}"; _CT_P_DATE="${5:-}"
  CT_MARKER=""
  out=""; i=0; n=${#tpl}
  while [ "$i" -lt "$n" ]; do
    if [ "${tpl:i:1}" = "{" ]; then
      depth=1; j=$(( i + 1 ))
      while [ "$j" -lt "$n" ] && [ "$depth" -gt 0 ]; do
        case "${tpl:j:1}" in
          '{') depth=$(( depth + 1 )) ;;
          '}') depth=$(( depth - 1 )) ;;
        esac
        j=$(( j + 1 ))
      done
      # An unbalanced brace cannot reach here: ct_is_valid_marker rejects the
      # template and the loader falls back to the default. Treated as literal
      # rather than dropped, so a bug upstream degrades to visible text.
      if [ "$depth" -ne 0 ]; then
        _ct_span "${tpl:i}"; out="$out$_CT_SPAN"; i="$n"; continue
      fi
      grp="${tpl:i+1:j-i-2}"
      if _ct_all_empty "$grp"; then
        :
      elif _ct_has_ph "$grp"; then
        _ct_span "$grp"; out="$out$_CT_SPAN"
      else
        out="$out{$grp}"
      fi
      i="$j"
    else
      k="$i"
      while [ "$k" -lt "$n" ] && [ "${tpl:k:1}" != "{" ]; do k=$(( k + 1 )); done
      _ct_span "${tpl:i:k-i}"; out="$out$_CT_SPAN"
      i="$k"
    fi
  done
  # shellcheck disable=SC2034  # CT_MARKER is this library's public interface
  CT_MARKER="$out"
  return 0
}

# Whether a template is renderable: no unknown placeholder, no unbalanced
# brace, and no nested group.
#
# A '%' followed by letters must spell one of the four names. A typo is rejected
# rather than rendered literally, because a user who writes %elapsd wants to
# know it did nothing, not to read it back on every message. A '%' followed by
# anything else is literal, so "100%" needs no escaping.
#
# A '{' while already inside a group is rejected rather than supported: nesting
# only buys decoration inside decoration, which a flat template can already
# express, and the renderer only ever scans for a group's own top-level braces
# (_ct_span assumes no braces at all), so a nested group would be accepted here
# and mis-rendered there. Depth is capped at 1 instead of taught to the
# renderer.
ct_is_valid_marker() {
  local s="${1:-}"
  local i=0 n depth ch rc
  n=${#s}; depth=0
  while [ "$i" -lt "$n" ]; do
    ch="${s:i:1}"
    case "$ch" in
      '{')
        depth=$(( depth + 1 ))
        [ "$depth" -gt 1 ] && return 1
        i=$(( i + 1 ))
        ;;
      '}')
        depth=$(( depth - 1 ))
        [ "$depth" -lt 0 ] && return 1
        i=$(( i + 1 ))
        ;;
      '%')
        rc=0; _ct_word "$s" "$i" || rc=$?
        [ "$rc" -eq 1 ] && return 1
        if [ "$rc" -eq 0 ]; then i=$(( i + _CT_WLEN )); else i=$(( i + 1 )); fi
        ;;
      *) i=$(( i + 1 )) ;;
    esac
  done
  [ "$depth" -eq 0 ]
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
