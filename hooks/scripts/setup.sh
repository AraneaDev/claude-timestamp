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

Flags
  --tz=ZONE                   IANA timezone (Europe/Amsterdam), or "local".
  --display=FORMAT            24h | short | 12h | iso | any strftime string.
  --context=FORMAT            Same values; used for the model-facing time.
  --color=COLOR               none | dim | gray | cyan | blue | green
                              | yellow | magenta | red.
  --elapsed=on|off            Show how long the turn took.
  --date-rollover=on|off      Show the date when a session crosses midnight.
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
  local body
  body="$(ct_now "$CT_DISPLAY_FORMAT")"
  [ "$CT_ELAPSED" = "on" ] && body="$body $(ct_format_elapsed 134)"
  printf '%s[%s]%s Sure, here is what I found.\n' \
    "$(ct_color_start "$CT_COLOR")" "$body" "$(ct_color_end "$CT_COLOR")"
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

# Show the date on the first message after the session crosses midnight.
DATE_ROLLOVER=$CT_DATE_ROLLOVER

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
  echo "  Date rollover   $CT_DATE_ROLLOVER"
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

  while [ $# -gt 0 ]; do
    case "$1" in
      --config=*)         CLAUDE_TIMESTAMP_CONFIG="${1#*=}"; export CLAUDE_TIMESTAMP_CONFIG ;;
      --tz=*)             set_tz="${1#*=}";      interactive=0 ;;
      --display=*)        set_display="${1#*=}"; interactive=0 ;;
      --context=*)        set_context="${1#*=}"; interactive=0 ;;
      --color=*)          set_color="${1#*=}";   interactive=0 ;;
      --elapsed=*)        set_elapsed="${1#*=}"; interactive=0 ;;
      --date-rollover=*)  set_rollover="${1#*=}"; interactive=0 ;;
      --inject-context=*) set_inject="${1#*=}";  interactive=0 ;;
      --show)             action="show"; interactive=0 ;;
      -h|--help)          usage; exit 0 ;;
      *) echo "Unknown argument: $1" >&2; echo >&2; usage >&2; exit 2 ;;
    esac
    shift
  done

  if [ "$action" = "show" ]; then show_config; exit 0; fi
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

  write_config
  echo -n "Preview: "; preview
}

main "$@"
