#!/usr/bin/env bash
# Configuration tool for claude-timestamp.
#
# Two entry points, one code path:
#
#   setup.sh                     interactive wizard, previews each choice
#   setup.sh --tz=CET --color=none   non-interactive write, no prompts
#
# The non-interactive form exists because the /timestamps slash command cannot
# drive an interactive prompt -- Claude Code's Bash tool has no interactive
# stdin. So the command asks the questions conversationally and calls this
# script with flags. Same script, same validation, same config file.
#
# Any flag switches off the wizard. Unspecified settings keep their current
# value rather than reverting to defaults, so `--color=none` changes exactly
# one thing.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/config.sh"

ZONEINFO="/usr/share/zoneinfo"

usage() {
  cat <<'USAGE'
claude-timestamp setup

  setup.sh                    Interactive wizard.
  setup.sh [flags]            Write settings without prompting.
  setup.sh --show             Print the current configuration.
  setup.sh --doctor           Check that everything needed is present and working.

Flags
  --tz=ZONE                   IANA timezone (Europe/Amsterdam), or "local".
  --display=FORMAT            24h | short | 12h | iso | any strftime string.
  --context=FORMAT            Same values; used for the model-facing time.
  --color=COLOR               none | dim | gray | cyan | blue | green
                              | yellow | magenta | red.
  --elapsed=on|off            Show how long the turn took.
  --slow-after=SECONDS        Colour the duration once a turn takes this long
                              (0 disables).
  --slow-color=COLOR          Colour used for a slow turn.
  --idle-after=SECONDS        Mark a gap between messages this long (0 disables).
  --date-rollover=on|off      Show the date when a session crosses midnight.
  --summary=on|off            Report session totals when the session ends.
  --subagents=on|off          Stamp subagent messages too.
  --tool-timing=on|off        Time individual tool calls and report the
                              slowest in the session summary. Off by default:
                              it is the only setting that costs anything per
                              tool call rather than per message.
  --inject-context=true|false Tell Claude the time each prompt was sent.
  --config=PATH               Write somewhere other than the default file.
  -h, --help                  This text.

Formats
  24h    14:03:22        short  14:03
  12h    2:03 PM         iso    2026-08-19T14:03:22
USAGE
}

# --- validation -------------------------------------------------------------
# Each validator prints nothing on success and an explanation on failure, so a
# bad flag from the slash command produces a message worth relaying.

valid_tz() {
  local tz="$1"
  [ "$tz" = "local" ] && return 0
  [ -z "$tz" ] && return 0
  case "$tz" in
    */../*|/*) echo "Timezone must be an IANA name like Europe/Amsterdam." >&2; return 1 ;;
  esac
  # Checked functionally rather than by looking for a zoneinfo file, because a
  # platform without the database (Git Bash on Windows) does not fail on an
  # unknown zone -- it silently renders UTC. Writing a pinned zone there would
  # produce a config that lies.
  # UTC and GMT need no database, so they stay configurable everywhere.
  case "$tz" in UTC|GMT) return 0 ;; esac
  if ! ct_tz_supported; then
    echo "This system has no timezone database, so a pinned zone would silently render as UTC." >&2
    echo "Use --tz=local to follow the machine's own clock instead." >&2
    return 1
  fi
  if [ -d "$ZONEINFO" ] && [ ! -f "$ZONEINFO/$tz" ]; then
    echo "Unknown timezone '$tz'. Expected an IANA name such as Europe/Amsterdam or Asia/Tokyo." >&2
    return 1
  fi
}

valid_color() {
  case "$1" in
    none|off|dim|gray|grey|red|green|yellow|blue|magenta|cyan) return 0 ;;
    *) echo "Unknown color '$1'. Pick: none dim gray red green yellow blue magenta cyan." >&2; return 1 ;;
  esac
}

valid_seconds() {
  case "$2" in
    ''|*[!0-9]*) echo "$1 must be a whole number of seconds, got '$2'." >&2; return 1 ;;
    *) return 0 ;;
  esac
}

valid_onoff() {
  case "$2" in on|off) return 0 ;; *) echo "$1 must be 'on' or 'off', got '$2'." >&2; return 1 ;; esac
}

valid_bool() {
  case "$2" in true|false) return 0 ;; *) echo "$1 must be 'true' or 'false', got '$2'." >&2; return 1 ;; esac
}

# --- rendering --------------------------------------------------------------

# Draw the marker exactly as message-display.sh would, so a preview is not a
# separate implementation that can drift from the real thing.
preview() {
  local sample=134 body elapsed base_start base_end
  base_start="$(ct_color_start "$CT_COLOR")"
  base_end="$(ct_color_end "$CT_COLOR")"
  body="$(ct_now "$CT_DISPLAY_FORMAT")"
  if [ "$CT_ELAPSED" = "on" ]; then
    elapsed="$(ct_format_elapsed "$sample")"
    # Mirrors the slow-turn branch in message-display.sh, so a preview showing
    # an unpainted duration always means the threshold really was not crossed.
    if [ "$CT_SLOW_AFTER" -gt 0 ] 2>/dev/null && [ "$sample" -ge "$CT_SLOW_AFTER" ]; then
      body="$body $(ct_paint "$CT_SLOW_COLOR" "$elapsed")$base_start"
    else
      body="$body $elapsed"
    fi
  fi
  printf '%s[%s]%s Sure, here is what I found.\n' "$base_start" "$body" "$base_end"
}

# A single place to answer "why is it not doing what I configured". Everything
# here is something that has actually gone wrong: a missing jq, a config that
# does not parse, or a pinned zone the platform cannot resolve.
doctor() {
  local problems=0
  ct_load_config

  echo "claude-timestamp doctor"
  echo

  echo "Platform"
  echo "  uname           $(uname -s)"
  if date --version >/dev/null 2>&1; then
    echo "  date            $(date --version | head -1)"
  else
    echo "  date            BSD or other non-GNU date"
  fi
  echo "  zoneinfo        $([ -d "$ZONEINFO" ] && echo "present" || echo "absent")"
  echo

  echo "Dependencies"
  if command -v jq >/dev/null 2>&1; then
    echo "  jq              $(jq --version)"
  else
    echo "  jq              MISSING - timestamps are disabled entirely."
    echo "                  macOS: brew install jq | Debian: sudo apt-get install jq"
    echo "                  Windows: winget install jqlang.jq"
    problems=$((problems + 1))
  fi
  echo "  bash            ${BASH_VERSION:-unknown}"
  echo

  echo "Configuration"
  local file
  file="$(ct_config_path)"
  if [ -r "$file" ]; then
    echo "  file            $file"
  else
    echo "  file            $file (absent, using defaults)"
  fi
  echo "  timezone        ${CT_TZ:-<machine local>}"
  if ct_tz_unhonoured; then
    echo "                  PROBLEM - this platform cannot resolve '$CT_TZ',"
    echo "                  so local time is shown instead. Use --tz=local, or"
    echo "                  UTC/GMT which need no timezone database."
    problems=$((problems + 1))
  fi
  echo "  display format  $CT_DISPLAY_FORMAT -> $(ct_now "$CT_DISPLAY_FORMAT")"
  echo "  context format  $CT_CONTEXT_FORMAT -> $(ct_now "$CT_CONTEXT_FORMAT") $(ct_zone)"
  echo "  color           $CT_COLOR$([ -n "${NO_COLOR:-}" ] && echo " (overridden: NO_COLOR is set)")"
  echo "  elapsed         $CT_ELAPSED"
  echo "  slow after      $([ "$CT_SLOW_AFTER" -gt 0 ] 2>/dev/null && echo "${CT_SLOW_AFTER}s in $CT_SLOW_COLOR" || echo "off")"
  echo "  idle marker     $([ "$CT_IDLE_AFTER" -gt 0 ] 2>/dev/null && echo "after ${CT_IDLE_AFTER}s" || echo "off")"
  echo "  date rollover   $CT_DATE_ROLLOVER"
  echo "  summary         $CT_SUMMARY"
  echo "  subagents       $CT_SUBAGENTS"
  echo "  tool timing     $CT_TOOL_TIMING$([ "$CT_TOOL_TIMING" = "on" ] && [ -z "${EPOCHREALTIME:-}" ] && echo " (whole seconds only: bash ${BASH_VERSION%%.*} has no EPOCHREALTIME)")"
  echo

  echo "State"
  local dir
  dir="$(ct_state_dir)"
  if mkdir -p "$dir" 2>/dev/null && [ -w "$dir" ]; then
    echo "  directory       $dir (writable)"
  else
    echo "  directory       $dir NOT WRITABLE - elapsed time and the summary"
    echo "                  will not work."
    problems=$((problems + 1))
  fi
  echo

  echo -n "Preview           "; preview
  echo
  if [ "$problems" -eq 0 ]; then
    echo "No problems found."
  else
    echo "$problems problem(s) found, described above."
    return 1
  fi
}

write_config() {
  local file dir
  file="$(ct_config_path)"
  dir="$(dirname "$file")"
  mkdir -p "$dir"
  cat > "$file" <<CONF
# claude-timestamp configuration
# Written by setup.sh -- safe to edit by hand. Run /timestamps to change it
# interactively. Unknown keys are ignored.

# IANA timezone name, or empty for the machine's local time.
TZ=$CT_TZ

# 24h | short | 12h | iso, or any strftime string (anything with a % in it).
DISPLAY_FORMAT=$CT_DISPLAY_FORMAT
CONTEXT_FORMAT=$CT_CONTEXT_FORMAT

# none dim gray red green yellow blue magenta cyan. NO_COLOR also disables it.
COLOR=$CT_COLOR

# Show how long the turn took, e.g. [14:03 +2m14s].
ELAPSED=$CT_ELAPSED

# Colour the duration once a turn takes at least this many seconds. 0 disables.
SLOW_AFTER=$CT_SLOW_AFTER
SLOW_COLOR=$CT_SLOW_COLOR

# Mark a gap of at least this many seconds between messages. 0 disables.
IDLE_AFTER=$CT_IDLE_AFTER

# Show the date on the first message after the session crosses midnight.
DATE_ROLLOVER=$CT_DATE_ROLLOVER

# Report how long the session ran, and how much of it was spent waiting.
SUMMARY=$CT_SUMMARY

# Stamp messages from subagents as well as the main conversation.
SUBAGENTS=$CT_SUBAGENTS

# Time individual tool calls and name the slowest in the session summary.
# The only setting that costs anything per tool call rather than per message.
TOOL_TIMING=$CT_TOOL_TIMING

# Tell Claude the local time each prompt was sent.
INJECT_CONTEXT=$CT_INJECT_CONTEXT
CONF
  echo "Wrote $file"
}

show_config() {
  ct_load_config
  local file
  file="$(ct_config_path)"
  if [ -r "$file" ]; then echo "Config: $file"; else echo "Config: $file (not created yet, showing defaults)"; fi
  echo
  echo "  Timezone        ${CT_TZ:-<machine local>}"
  echo "  Display format  $CT_DISPLAY_FORMAT"
  echo "  Context format  $CT_CONTEXT_FORMAT"
  echo "  Color           $CT_COLOR"
  echo "  Elapsed         $CT_ELAPSED"
  echo "  Slow after      $CT_SLOW_AFTER s in $CT_SLOW_COLOR"
  echo "  Idle marker     $CT_IDLE_AFTER s"
  echo "  Date rollover   $CT_DATE_ROLLOVER"
  echo "  Summary         $CT_SUMMARY"
  echo "  Subagents       $CT_SUBAGENTS"
  echo "  Tool timing     $CT_TOOL_TIMING"
  echo "  Inject context  $CT_INJECT_CONTEXT"
  echo
  echo -n "  Preview         "; preview
}

# --- wizard -----------------------------------------------------------------

detect_tz() {
  if [ -n "${TZ:-}" ]; then printf '%s' "$TZ"; return; fi
  if [ -r /etc/timezone ]; then tr -d '[:space:]' < /etc/timezone; return; fi
  if [ -L /etc/localtime ]; then
    local target; target="$(readlink -f /etc/localtime)"
    case "$target" in "$ZONEINFO"/*) printf '%s' "${target#"$ZONEINFO"/}"; return ;; esac
  fi
  printf ''
}

ask() {
  local prompt="$1" default="$2" answer
  read -r -p "$prompt [$default]: " answer </dev/tty || answer=""
  printf '%s' "${answer:-$default}"
}

wizard() {
  ct_load_config

  echo "claude-timestamp setup"
  echo "Press Enter to keep the value in brackets."
  echo

  # Timezone
  local detected current answer
  detected="$(detect_tz)"
  current="${CT_TZ:-${detected:-local}}"
  echo "Timezone. Type an IANA name (Europe/Amsterdam), or 'local' for this"
  echo "machine's own time. Type 'list' to search the installed zones."
  while :; do
    answer="$(ask "  Timezone" "$current")"
    if [ "$answer" = "list" ]; then
      local term
      term="$(ask "  Search for" "Europe")"
      if [ -d "$ZONEINFO" ]; then
        find "$ZONEINFO" -type f -path "*$term*" 2>/dev/null \
          | sed "s|^$ZONEINFO/||" | grep -v '^posix/\|^right/\|\.' | sort | head -25
      else
        echo "  No zoneinfo database on this machine; type the name directly."
      fi
      continue
    fi
    if valid_tz "$answer"; then
      [ "$answer" = "local" ] && CT_TZ="" || CT_TZ="$answer"
      break
    fi
  done
  echo

  # Display format
  echo "Clock format for the marker on screen."
  local fmt
  while :; do
    echo "  24h = $(ct_now 24h)   short = $(ct_now short)   12h = $(ct_now 12h)   iso = $(ct_now iso)"
    fmt="$(ask "  Display format" "$CT_DISPLAY_FORMAT")"
    case "$fmt" in
      24h|short|12h|iso|*%*) CT_DISPLAY_FORMAT="$fmt"; break ;;
      *) echo "  Pick 24h, short, 12h, iso, or a strftime string containing %." ;;
    esac
  done
  echo

  # Elapsed
  answer="$(ask "Show how long each turn took? (on/off)" "$CT_ELAPSED")"
  case "$answer" in on|off) CT_ELAPSED="$answer" ;; esac
  echo

  # Duration extras, only worth asking about when durations are shown at all.
  if [ "$CT_ELAPSED" = "on" ]; then
    while :; do
      answer="$(ask "  Colour the duration after how many seconds? (0 = never)" "$CT_SLOW_AFTER")"
      if valid_seconds SLOW_AFTER "$answer"; then CT_SLOW_AFTER="$answer"; break; fi
    done
  fi
  while :; do
    answer="$(ask "Mark a gap between messages after how many seconds? (0 = never)" "$CT_IDLE_AFTER")"
    if valid_seconds IDLE_AFTER "$answer"; then CT_IDLE_AFTER="$answer"; break; fi
  done
  answer="$(ask "Report session totals when the session ends? (on/off)" "$CT_SUMMARY")"
  case "$answer" in on|off) CT_SUMMARY="$answer" ;; esac
  if [ "$CT_SUMMARY" = "on" ]; then
    echo "  Tool timing names the slowest tools in that summary. It is the only"
    echo "  setting that costs anything per tool call rather than per message."
    answer="$(ask "  Time individual tool calls? (on/off)" "$CT_TOOL_TIMING")"
    case "$answer" in on|off) CT_TOOL_TIMING="$answer" ;; esac
  fi
  echo

  # Color
  echo "Color for the marker."
  local c
  for c in dim gray cyan blue green yellow magenta red; do
    printf '  %-8s %s%s%s\n' "$c" "$(ct_color_start "$c")" "[$(ct_now "$CT_DISPLAY_FORMAT")]" "$(ct_color_end "$c")"
  done
  echo "  none     [$(ct_now "$CT_DISPLAY_FORMAT")]"
  while :; do
    answer="$(ask "  Color" "$CT_COLOR")"
    if valid_color "$answer"; then CT_COLOR="$answer"; break; fi
  done
  echo

  # Model-facing context
  echo "Claude can also be told the local time each prompt was sent, so it can"
  echo "reason about when things happened. This costs a few tokens per message."
  answer="$(ask "  Tell Claude the time? (true/false)" "$CT_INJECT_CONTEXT")"
  case "$answer" in true|false) CT_INJECT_CONTEXT="$answer" ;; esac
  if [ "$CT_INJECT_CONTEXT" = "true" ]; then
    while :; do
      fmt="$(ask "  Format Claude sees" "$CT_CONTEXT_FORMAT")"
      case "$fmt" in
        24h|short|12h|iso|*%*) CT_CONTEXT_FORMAT="$fmt"; break ;;
        *) echo "  Pick 24h, short, 12h, iso, or a strftime string containing %." ;;
      esac
    done
  fi
  echo

  echo -n "Result: "; preview
  echo
  answer="$(ask "Write this configuration? (y/n)" "y")"
  case "$answer" in
    y|Y|yes) write_config; echo "Restart Claude Code, or start a new session, to pick it up." ;;
    *) echo "Nothing written." ;;
  esac
}

# --- entry point ------------------------------------------------------------

main() {
  local interactive=1 action="write"
  local set_tz="" set_display="" set_context="" set_color="" set_elapsed="" set_inject="" set_rollover=""
  local set_slow="" set_slowcolor="" set_idle="" set_summary="" set_subagents="" set_tooltiming=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --config=*)         CLAUDE_TIMESTAMP_CONFIG="${1#*=}"; export CLAUDE_TIMESTAMP_CONFIG ;;
      --tz=*)             set_tz="${1#*=}";      interactive=0 ;;
      --display=*)        set_display="${1#*=}"; interactive=0 ;;
      --context=*)        set_context="${1#*=}"; interactive=0 ;;
      --color=*)          set_color="${1#*=}";   interactive=0 ;;
      --elapsed=*)        set_elapsed="${1#*=}"; interactive=0 ;;
      --date-rollover=*)  set_rollover="${1#*=}"; interactive=0 ;;
      --slow-after=*)     set_slow="${1#*=}";      interactive=0 ;;
      --slow-color=*)     set_slowcolor="${1#*=}"; interactive=0 ;;
      --idle-after=*)     set_idle="${1#*=}";      interactive=0 ;;
      --summary=*)        set_summary="${1#*=}";   interactive=0 ;;
      --subagents=*)      set_subagents="${1#*=}"; interactive=0 ;;
      --tool-timing=*)    set_tooltiming="${1#*=}"; interactive=0 ;;
      --inject-context=*) set_inject="${1#*=}";  interactive=0 ;;
      --show)             action="show"; interactive=0 ;;
      --doctor)           action="doctor"; interactive=0 ;;
      -h|--help)          usage; exit 0 ;;
      *) echo "Unknown argument: $1" >&2; echo >&2; usage >&2; exit 2 ;;
    esac
    shift
  done

  if [ "$action" = "show" ]; then show_config; exit 0; fi
  if [ "$action" = "doctor" ]; then doctor; exit $?; fi
  if [ "$interactive" = "1" ]; then wizard; exit 0; fi

  # Non-interactive: start from what is already configured so each flag is a
  # targeted change rather than a full overwrite.
  ct_load_config

  if [ -n "$set_tz" ]; then
    valid_tz "$set_tz" || exit 2
    [ "$set_tz" = "local" ] && CT_TZ="" || CT_TZ="$set_tz"
  fi
  [ -n "$set_display" ] && CT_DISPLAY_FORMAT="$set_display"
  [ -n "$set_context" ] && CT_CONTEXT_FORMAT="$set_context"
  if [ -n "$set_color" ];   then valid_color "$set_color" || exit 2; CT_COLOR="$set_color"; fi
  if [ -n "$set_elapsed" ]; then valid_onoff ELAPSED "$set_elapsed" || exit 2; CT_ELAPSED="$set_elapsed"; fi
  if [ -n "$set_inject" ];  then valid_bool INJECT_CONTEXT "$set_inject" || exit 2; CT_INJECT_CONTEXT="$set_inject"; fi
  if [ -n "$set_rollover" ]; then valid_onoff DATE_ROLLOVER "$set_rollover" || exit 2; CT_DATE_ROLLOVER="$set_rollover"; fi
  if [ -n "$set_slow" ]; then valid_seconds SLOW_AFTER "$set_slow" || exit 2; CT_SLOW_AFTER="$set_slow"; fi
  if [ -n "$set_idle" ]; then valid_seconds IDLE_AFTER "$set_idle" || exit 2; CT_IDLE_AFTER="$set_idle"; fi
  if [ -n "$set_slowcolor" ]; then valid_color "$set_slowcolor" || exit 2; CT_SLOW_COLOR="$set_slowcolor"; fi
  if [ -n "$set_summary" ]; then valid_onoff SUMMARY "$set_summary" || exit 2; CT_SUMMARY="$set_summary"; fi
  if [ -n "$set_subagents" ]; then valid_onoff SUBAGENTS "$set_subagents" || exit 2; CT_SUBAGENTS="$set_subagents"; fi
  if [ -n "$set_tooltiming" ]; then valid_onoff TOOL_TIMING "$set_tooltiming" || exit 2; CT_TOOL_TIMING="$set_tooltiming"; fi

  write_config
  echo -n "Preview: "; preview
}

main "$@"
