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

CT_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
source "$CT_LIB/config.sh"
source "$CT_LIB/state.sh"

ZONEINFO="/usr/share/zoneinfo"

usage() {
  cat <<'USAGE'
claude-timestamp setup

  setup.sh                    Interactive wizard.
  setup.sh [flags]            Write settings without prompting.
  setup.sh --show             Print the current configuration.
  setup.sh --doctor           Check that everything needed is present and working.
  setup.sh --stats            Summarise the sessions recorded so far.

Flags
  --tz=ZONE                   IANA timezone (Europe/Amsterdam), or "local".
  --display=FORMAT            24h | short | 12h | iso | any strftime string.
  --context=FORMAT            Same values; used for the model-facing time.
  --color=COLOR               none | dim | gray | cyan | blue | green
                              | yellow | magenta | red.
  --marker=TEMPLATE           The marker's layout. %time %elapsed %tool %date
                              are the parts; a {...} group disappears when
                              every part inside it is empty.
  --time-color=COLOR          Colour of %time. inherit follows --color, which
                              is also the default.
  --elapsed-color=COLOR       Colour of %elapsed, or inherit. A slow turn
                              still uses --slow-color.
  --tool-color=COLOR          Colour of %tool. inherit follows --color, which
                              is also the default.
  --elapsed=on|off            Show how long the turn took.
  --slow-after=SECONDS        Colour the duration once a turn takes this long
                              (0 disables).
  --slow-color=COLOR          Colour used for a slow turn.
  --idle-after=SECONDS        Mark a gap between messages this long (0 disables).
  --date-rollover=on|off      Show the date when a session crosses midnight.
  --summary=on|off            Report session totals when the session ends.
  --subagents=on|off          Stamp subagent messages too.
  --history=on|off            Record each finished session for --stats.
  --history-limit=N           How many sessions to keep (default 200).
  --tool-timing=on|off        Record what each tool call cost and report the
                              slowest in the session summary. Off by default:
                              it is the only setting that costs anything per
                              tool call rather than per message.
  --inject-context=true|false Tell Claude the time each prompt was sent.
  --enabled=on|off            Master switch. off silences every hook without
                              uninstalling the plugin.
  --project                   Write to this project instead of your account,
                              at .claude/claude-timestamp.conf in the current
                              directory. Only the settings you name are
                              written, so the rest keep following your own
                              configuration.
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
  if ! ct_is_valid_tz "$tz"; then
    echo "Timezone must be an IANA name like Europe/Amsterdam." >&2
    return 1
  fi
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
  ct_is_valid_color "$1" && return 0
  echo "Unknown color '$1'. Pick: none dim gray red green yellow blue magenta cyan." >&2
  return 1
}

valid_marker() {
  ct_is_valid_marker "$1" && return 0
  echo "That marker template is not usable. The parts are %time, %elapsed, %tool and %date," >&2
  echo "a {...} group disappears when every part inside it is empty, and braces must balance." >&2
  return 1
}

valid_part_color() {
  ct_is_valid_part_color "$1" && return 0
  echo "Unknown colour '$1'. Pick: none dim gray red green yellow blue magenta cyan, or 'inherit' to follow COLOR." >&2
  return 1
}

# Apply a --time-color/--elapsed-color/--tool-color flag, distinguishing three
# cases that all reduce to the empty string once the flag is split on '=':
# the flag absent entirely (do nothing), --foo=inherit (explicitly follow
# COLOR, the same sentinel role --tz=local plays for TZ), and a bare --foo=
# (rejected -- unlike TZ, this flag's empty value already has a meaning of its
# own, so a bare empty cannot double as "not named" the way it does elsewhere).
apply_part_color() {
  local flag="$1" named="$2" value="$3" var="$4"
  [ "$named" = "1" ] || return 0
  case "$value" in
    inherit) value="" ;;
    '')
      echo "$flag needs a value: a colour name, or 'inherit' to follow --color." >&2
      exit 2
      ;;
  esac
  valid_part_color "$value" || exit 2
  printf -v "$var" '%s' "$value"
}

valid_seconds() {
  ct_is_seconds "$2" && return 0
  echo "$1 must be a whole number of seconds, got '$2'." >&2
  return 1
}

valid_onoff() {
  ct_is_onoff "$2" && return 0
  echo "$1 must be 'on' or 'off', got '$2'." >&2
  return 1
}

valid_bool() {
  ct_is_bool "$2" && return 0
  echo "$1 must be 'true' or 'false', got '$2'." >&2
  return 1
}

# --- rendering --------------------------------------------------------------

# Draw the marker exactly as message-display.sh would, so a preview is not a
# separate implementation that can drift from the real thing.
preview() {
  local sample=134 elapsed elapsed_color p_time p_elapsed p_tool
  ct_paint_part "$CT_TIME_COLOR" "$(ct_now "$CT_DISPLAY_FORMAT")" "$CT_COLOR"; p_time="$_CT_PART"
  p_elapsed=""
  if [ "$CT_ELAPSED" = "on" ]; then
    elapsed="$(ct_format_elapsed "$sample")"
    elapsed_color="$CT_ELAPSED_COLOR"
    # Mirrors the slow-turn branch in message-display.sh, so a preview showing
    # an unpainted duration always means the threshold really was not crossed.
    if [ "$CT_SLOW_AFTER" -gt 0 ] 2>/dev/null && [ "$sample" -ge "$CT_SLOW_AFTER" ]; then
      elapsed_color="$CT_SLOW_COLOR"
    fi
    ct_paint_part "$elapsed_color" "$elapsed" "$CT_COLOR"; p_elapsed="$_CT_PART"
  fi
  p_tool=""
  if [ "$CT_TOOL_TIMING" = "on" ]; then
    ct_paint_part "$CT_TOOL_COLOR" "Bash 1m58s" "$CT_COLOR"; p_tool="$_CT_PART"
  fi
  ct_render_marker "$CT_MARKER_TEMPLATE" "$p_time" "$p_elapsed" "$p_tool" ""
  printf '%s%s%s Sure, here is what I found.\n' "$(ct_color_start "$CT_COLOR")" "$CT_MARKER" "$(ct_color_end "$CT_COLOR")"
  # Every other line in this sample is real: the actual color, the actual
  # format. This one is not -- with the plugin off, no hook draws it, so a
  # reader who only skims the marker should not walk away thinking it works.
  [ "$CT_ENABLED" = "on" ] || echo "(sample only -- ENABLED=$CT_ENABLED, so no hook actually draws this)"
}

# What the recorded sessions add up to.
#
# The history holds timings only, so everything here is arithmetic on six
# numbers per session. Durations are formatted in the shell rather than in awk
# because ct_format_duration already exists and should not be reimplemented.
stats() {
  ct_load_config

  local file
  file="$(ct_history_path)"
  if [ ! -r "$file" ] || [ ! -s "$file" ]; then
    echo "No sessions recorded yet."
    if [ "$CT_HISTORY" != "on" ]; then
      echo "History is switched off. Turn it on with --history=on."
    else
      echo "A session is recorded when it ends, so there will be one shortly."
      echo "Only sessions with at least one prompt are recorded."
    fi
    return 0
  fi

  local n total turns waited idle failed maxd maxwhen maxturns first last
  read -r n total turns waited idle failed maxd maxwhen maxturns first last <<EOF
$(awk -F'\t' '
  {
    n++; total += $2; turns += $3; waited += $4; idle += $5; failed += $6
    if ($2 + 0 > maxd + 0) { maxd = $2; maxwhen = $1; maxturns = $3 }
    if (first == "") first = $1
    last = $1
  }
  END {
    if (n == 0) { print "0 0 0 0 0 0 0 - 0 - -"; exit }
    printf "%d %d %d %d %d %d %d %s %d %s %s\n",
      n, total, turns, waited, idle, failed, maxd, maxwhen, maxturns, first, last
  }' "$file")
EOF

  printf 'claude-timestamp stats%*slast %s session' "$((28 - 21))" "" "$n"
  [ "$n" -eq 1 ] || printf 's'
  printf '\n\n'

  echo "  sessions        $n"
  echo "  total time      $(ct_format_duration "$total")"
  if [ "$total" -gt 0 ]; then
    echo "  waiting         $(ct_format_duration "$waited")  ($(( waited * 100 / total ))% of it)"
  else
    echo "  waiting         $(ct_format_duration "$waited")"
  fi
  [ "$idle" -gt 0 ] && echo "  away            $(ct_format_duration "$idle")"
  echo "  turns           $turns"
  [ "$turns" -gt 0 ] && echo "  average wait    $(ct_format_duration "$(( waited / turns ))") per turn"
  [ "$failed" -gt 0 ] && echo "  failed tools    $failed"
  echo
  echo "  longest         ${maxwhen%%T*}  $(ct_format_duration "$maxd") over $maxturns turns"
  echo "  recorded from   ${first%%T*} to ${last%%T*}"
  return 0
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
  echo "  enabled         $CT_ENABLED$([ "$CT_ENABLED" != "on" ] && echo " - the plugin is switched off; nothing below is actually running")"
  if [ -n "${CT_CONFIG_PROBLEMS:-}" ]; then
    echo "  PROBLEMS"
    printf '%s\n' "$CT_CONFIG_PROBLEMS" | sed 's/^  /    /'
    problems=$((problems + 1))
  fi
  local file
  file="$(ct_config_path)"
  if [ -r "$file" ]; then
    echo "  file            $(ct_tilde "$file")"
  else
    echo "  file            $(ct_tilde "$file") (absent, using defaults)"
  fi
  if [ -n "${CT_PROJECT_CONFIG:-}" ]; then
    echo "  project file    $(ct_tilde "$CT_PROJECT_CONFIG")"
  else
    echo "  project file    none for this directory"
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
  echo "  marker          $CT_MARKER_TEMPLATE"
  echo "  part colours    time ${CT_TIME_COLOR:-<inherit>}, elapsed ${CT_ELAPSED_COLOR:-<inherit>}, tool ${CT_TOOL_COLOR:-<inherit>}"
  echo "  entrypoint      ${CLAUDE_CODE_ENTRYPOINT:-<unset>}$(case "${CLAUDE_CODE_ENTRYPOINT-cli}" in cli) ;; *) { [ -n "${NO_COLOR:-}" ] || [ -n "${FORCE_COLOR:-}" ]; } || echo " (colour suppressed: not a terminal session)" ;; esac)"
  echo "  elapsed         $CT_ELAPSED"
  echo "  slow after      $([ "$CT_SLOW_AFTER" -gt 0 ] 2>/dev/null && echo "${CT_SLOW_AFTER}s in $CT_SLOW_COLOR" || echo "off")"
  echo "  idle marker     $([ "$CT_IDLE_AFTER" -gt 0 ] 2>/dev/null && echo "after ${CT_IDLE_AFTER}s" || echo "off")"
  echo "  date rollover   $CT_DATE_ROLLOVER"
  echo "  summary         $CT_SUMMARY"
  echo "  subagents       $CT_SUBAGENTS"
  echo "  history         $CT_HISTORY, keeping $CT_HISTORY_LIMIT"
  echo "  tool timing     $CT_TOOL_TIMING"
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

# Master switch. off silences every hook without uninstalling the plugin.
ENABLED=$CT_ENABLED

# IANA timezone name, or empty for the machine's local time.
TZ=$CT_TZ

# 24h | short | 12h | iso, or any strftime string (anything with a % in it).
DISPLAY_FORMAT=$CT_DISPLAY_FORMAT
CONTEXT_FORMAT=$CT_CONTEXT_FORMAT

# none dim gray red green yellow blue magenta cyan. NO_COLOR also disables it.
COLOR=$CT_COLOR

# The marker's layout. %time %elapsed %tool %date are the parts, and a {...}
# group disappears when every part inside it is empty.
MARKER=$CT_MARKER_TEMPLATE

# Colour of each part. Empty follows COLOR. A slow turn still uses SLOW_COLOR.
TIME_COLOR=$CT_TIME_COLOR
ELAPSED_COLOR=$CT_ELAPSED_COLOR
TOOL_COLOR=$CT_TOOL_COLOR

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

# Record what each tool call cost and name the slowest in the session summary.
# The only setting that costs anything per tool call rather than per message.
TOOL_TIMING=$CT_TOOL_TIMING

# Record each finished session, and how many to keep. Timings only: no message
# text, no tool arguments, no paths.
HISTORY=$CT_HISTORY
HISTORY_LIMIT=$CT_HISTORY_LIMIT

# Tell Claude the local time each prompt was sent.
INJECT_CONTEXT=$CT_INJECT_CONTEXT
CONF
  echo "Wrote $(ct_tilde "$file")"
}

# Write a project's own settings, keeping the file to just what it overrides.
#
# A project config exists to pin one or two things, so writing every setting
# would shadow the user's configuration entirely and silently freeze it at
# today's values. Only the settings named on the command line are written,
# merged with whatever the file already pinned.
write_project_config() {
  local file dir key value existing out="" marker_named named line ekey known
  file="$PWD/$CT_CONFIG_NAME"
  dir="$(dirname "$file")"
  mkdir -p "$dir"

  existing=""
  [ -r "$file" ] && existing="$(cat "$file")"

  # Read before `set --` below replaces the positional parameters this came
  # in on. MARKER is the one key whose legitimately-named value can itself be
  # the empty string (an empty template renders no prefix at all), so its
  # caller passes this alongside to say "named, even though empty" -- every
  # other key can tell "empty" and "not named" apart from the raw value alone
  # (TZ spells its empty case "local", the part colours spell theirs
  # "inherit", so an actually-empty value only ever means "not named").
  marker_named="${21:-}"

  set -- TZ "$1" DISPLAY_FORMAT "$2" CONTEXT_FORMAT "$3" COLOR "$4" \
         ELAPSED "$5" INJECT_CONTEXT "$6" DATE_ROLLOVER "$7" SLOW_AFTER "$8" \
         SLOW_COLOR "$9" IDLE_AFTER "${10}" SUMMARY "${11}" SUBAGENTS "${12}" \
         TOOL_TIMING "${13}" ENABLED "${14}" MARKER "${15}" TIME_COLOR "${16}" \
         ELAPSED_COLOR "${17}" TOOL_COLOR "${18}" HISTORY "${19}" HISTORY_LIMIT "${20}"

  known="|TZ|DISPLAY_FORMAT|CONTEXT_FORMAT|COLOR|ELAPSED|INJECT_CONTEXT|"
  known="${known}DATE_ROLLOVER|SLOW_AFTER|SLOW_COLOR|IDLE_AFTER|SUMMARY|"
  known="${known}SUBAGENTS|TOOL_TIMING|ENABLED|MARKER|TIME_COLOR|ELAPSED_COLOR|"
  known="${known}TOOL_COLOR|HISTORY|HISTORY_LIMIT|"

  while [ "$#" -gt 0 ]; do
    key="$1"; value="$2"; shift 2
    named=1
    [ -n "$value" ] || { [ "$key" = "MARKER" ] && [ "$marker_named" = "1" ]; } || named=0
    if [ "$named" = "0" ]; then
      # Not named now. Keep it only if this project already pinned it -- and
      # test that by whether the key is present in the file, not by whether
      # the value that comes back is empty. Both an absent key and a key
      # pinned to the empty string (TZ=, or a colour set to inherit) extract
      # as "", so emptiness alone cannot tell "nothing to keep" from "keep an
      # empty pin"; presence can.
      if printf '%s\n' "$existing" | grep -q "^${key}="; then
        value="$(printf '%s\n' "$existing" | sed -n "s/^${key}=//p" | tail -1)"
      else
        continue
      fi
    fi
    case "$key" in
      TZ)                                    [ "$value" = "local" ]    && value="" ;;
      TIME_COLOR|ELAPSED_COLOR|TOOL_COLOR)   [ "$value" = "inherit" ]  && value="" ;;
    esac
    out="${out}${key}=${value}
"
  done

  # A key this run does not recognise -- one a newer version of the plugin
  # wrote -- is carried over unchanged rather than dropped. lib/config.sh
  # promises that a config a newer version writes stays readable by an older
  # one; silently losing such a key the next time this (older) setup.sh
  # rewrites the file would break that promise the moment the file is
  # written, not merely read.
  if [ -n "$existing" ]; then
    while IFS= read -r line; do
      case "$line" in
        ''|'#'*) continue ;;
        *=*)     ekey="${line%%=*}" ;;
        *)       continue ;;
      esac
      case "$ekey" in
        *[![:upper:][:digit:]_]*|'') continue ;;
      esac
      case "$known" in
        *"|${ekey}|"*) continue ;;
      esac
      out="${out}${line}
"
    done < <(printf '%s\n' "$existing")
  fi

  if [ -z "$out" ]; then
    echo "Nothing to write: name at least one setting, for example --color=none." >&2
    return 1
  fi

  {
    echo "# claude-timestamp settings for this project"
    echo "# Layered over your own configuration, which still supplies everything"
    echo "# not listed here. Run /timestamps to change it."
    echo
    printf '%s' "$out"
  } > "$file"
  echo "Wrote $(ct_tilde "$file")"
}

show_config() {
  ct_load_config
  local file
  file="$(ct_config_path)"
  if [ -r "$file" ]; then
    echo "Config: $(ct_tilde "$file")"
  else
    echo "Config: $(ct_tilde "$file") (not created yet, showing defaults)"
  fi
  echo
  [ -n "${CT_PROJECT_CONFIG:-}" ] && echo "Project: $(ct_tilde "$CT_PROJECT_CONFIG") (layered on top)"
  echo
  echo "  Enabled         $CT_ENABLED"
  echo "  Timezone        ${CT_TZ:-<machine local>}"
  echo "  Display format  $CT_DISPLAY_FORMAT"
  echo "  Context format  $CT_CONTEXT_FORMAT"
  echo "  Color           $CT_COLOR"
  echo "  Marker          $CT_MARKER_TEMPLATE"
  echo "  Part colours    time ${CT_TIME_COLOR:-<inherit>}, elapsed ${CT_ELAPSED_COLOR:-<inherit>}, tool ${CT_TOOL_COLOR:-<inherit>}"
  echo "  Elapsed         $CT_ELAPSED"
  echo "  Slow after      $CT_SLOW_AFTER s in $CT_SLOW_COLOR"
  echo "  Idle marker     $CT_IDLE_AFTER s"
  echo "  Date rollover   $CT_DATE_ROLLOVER"
  echo "  Summary         $CT_SUMMARY"
  echo "  Subagents       $CT_SUBAGENTS"
  echo "  Tool timing     $CT_TOOL_TIMING"
  echo "  History         $CT_HISTORY (keeping $CT_HISTORY_LIMIT)"
  echo "  Inject context  $CT_INJECT_CONTEXT"
  echo
  echo -n "  Preview         "; preview
}

# --- wizard -----------------------------------------------------------------

# Terminal columns a string occupies, as opposed to its byte length.
#
# printf's own %-Ns field width pads by bytes, not columns, so a string
# carrying a multi-byte character (such as the template previews' `·` and `→`)
# comes out one or more columns short: the byte count includes each
# continuation byte, but a continuation byte draws nothing of its own. This is
# locale-independent by construction -- LC_ALL=C forces tr to work on raw
# bytes -- rather than relying on ${#s} or printf's width, either of which a
# non-UTF-8 locale can make byte-based again.
_ct_display_width() {
  local s="$1" bytes cont
  bytes="$(printf '%s' "$s" | wc -c | tr -d ' ')"
  cont="$(printf '%s' "$s" | LC_ALL=C tr -d -c '\200-\277' | wc -c | tr -d ' ')"
  printf '%d' "$((bytes - cont))"
}

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
  if [ -t 0 ]; then
    # Interactive: read the terminal directly, so the wizard still works when
    # something has redirected this script's stdin.
    read -r -p "$prompt [$default]: " answer </dev/tty || answer=""
  else
    # No terminal, so answers are being piped in. Reading stdin here is what
    # makes the wizard testable without a pseudo-terminal.
    #
    # The prompt goes to stderr because this function's stdout is captured by
    # the caller; printing it there would put the prompt inside the answer.
    printf '%s [%s]: ' "$prompt" "$default" >&2
    if ! read -r answer; then
      answer=""
      # Input is exhausted. Without this the re-ask loops below would spin
      # forever on a value that never becomes valid.
      CT_ASK_EOF=1
    fi
  fi
  printf '%s' "${answer:-$default}"
}

wizard() {
  ct_load_config

  echo "claude-timestamp setup"
  echo "Press Enter to keep the value in brackets."
  echo

  local answer
  local tpl wp_time wp_el wp_tool

  # Enabled
  echo "Master switch for the whole plugin. Off silences every hook without"
  echo "uninstalling it, and the rest of your settings stay put for next time."
  answer="$(ask "Enable claude-timestamp? (on/off)" "$CT_ENABLED")"
  case "$answer" in on|off) CT_ENABLED="$answer" ;; esac
  echo

  # Timezone
  local detected current
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
      [ -n "${CT_ASK_EOF:-}" ] && break
    done
  fi
  while :; do
    answer="$(ask "Mark a gap between messages after how many seconds? (0 = never)" "$CT_IDLE_AFTER")"
    if valid_seconds IDLE_AFTER "$answer"; then CT_IDLE_AFTER="$answer"; break; fi
    [ -n "${CT_ASK_EOF:-}" ] && break
  done
  answer="$(ask "Report session totals when the session ends? (on/off)" "$CT_SUMMARY")"
  case "$answer" in on|off) CT_SUMMARY="$answer" ;; esac
  if [ "$CT_SUMMARY" = "on" ]; then
    echo "  Tool timing names the slowest tools in that summary. It is the only"
    echo "  setting that costs anything per tool call rather than per message."
    answer="$(ask "  Record what each tool call cost? (on/off)" "$CT_TOOL_TIMING")"
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
    [ -n "${CT_ASK_EOF:-}" ] && break
  done
  echo

  # The marker's layout. Shown as three real renderings rather than described,
  # because a template is much easier to recognise than to read.
  echo "The marker's layout is a template. %time %elapsed %tool %date are the"
  echo "parts, and a {...} group disappears when every part inside it is empty."
  echo
  local tpl_width tpl_pad
  for tpl in '[{%date }%time{ %elapsed}{ · %tool}]' '%time' '%time{ → %elapsed}'; do
    ct_paint_part "$CT_TIME_COLOR"    "$(ct_now "$CT_DISPLAY_FORMAT")" "$CT_COLOR"; wp_time="$_CT_PART"
    ct_paint_part "$CT_ELAPSED_COLOR" "+2m14s"                          "$CT_COLOR"; wp_el="$_CT_PART"
    ct_paint_part "$CT_TOOL_COLOR"    "Bash 1m58s"                      "$CT_COLOR"; wp_tool="$_CT_PART"
    ct_render_marker "$tpl" "$wp_time" "$wp_el" "$wp_tool" ""
    # %-38s pads by bytes, not by the columns a multi-byte character such as
    # `·` or `→` actually draws, so two of these three templates would land
    # their preview one or two columns early. Padded by hand instead.
    tpl_width="$(_ct_display_width "$tpl")"
    tpl_pad=$(( 38 - tpl_width ))
    [ "$tpl_pad" -lt 0 ] && tpl_pad=0
    printf '  %s%*s %s%s%s\n' "$tpl" "$tpl_pad" "" \
      "$(ct_color_start "$CT_COLOR")" "$CT_MARKER" "$(ct_color_end "$CT_COLOR")"
  done
  while :; do
    answer="$(ask "  Marker" "$CT_MARKER_TEMPLATE")"
    if valid_marker "$answer"; then CT_MARKER_TEMPLATE="$answer"; break; fi
    # Input is exhausted, so re-asking would spin forever on a value that can
    # never become valid. Every other question here breaks the same way.
    [ -n "${CT_ASK_EOF:-}" ] && break
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
      [ -n "${CT_ASK_EOF:-}" ] && break
    done
  fi
  echo

  echo -n "Result: "; preview
  echo
  answer="$(ask "Write this configuration? (y/n)" "y")"
  case "$answer" in
    y|Y|yes) write_config; echo "This takes effect on your next message. No restart needed." ;;
    *) echo "Nothing written." ;;
  esac
}

# --- entry point ------------------------------------------------------------

main() {
  local interactive=1 action="write" project_scope=0
  local set_tz="" set_display="" set_context="" set_color="" set_elapsed="" set_inject="" set_rollover=""
  local set_slow="" set_slowcolor="" set_idle="" set_summary="" set_subagents="" set_tooltiming=""
  local set_history="" set_historylimit="" set_enabled=""
  local set_marker="" set_timecolor="" set_elapsedcolor="" set_toolcolor=""
  local marker_named=0 timecolor_named=0 elapsedcolor_named=0 toolcolor_named=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --config=*)         CLAUDE_TIMESTAMP_CONFIG="${1#*=}"; export CLAUDE_TIMESTAMP_CONFIG ;;
      --project)          project_scope=1; interactive=0 ;;
      --tz=*)             set_tz="${1#*=}";      interactive=0 ;;
      --display=*)        set_display="${1#*=}"; interactive=0 ;;
      --context=*)        set_context="${1#*=}"; interactive=0 ;;
      --color=*)          set_color="${1#*=}";   interactive=0 ;;
      --marker=*)         set_marker="${1#*=}";  marker_named=1; interactive=0 ;;
      --time-color=*)     set_timecolor="${1#*=}";    timecolor_named=1;    interactive=0 ;;
      --elapsed-color=*)  set_elapsedcolor="${1#*=}"; elapsedcolor_named=1; interactive=0 ;;
      --tool-color=*)     set_toolcolor="${1#*=}";    toolcolor_named=1;    interactive=0 ;;
      --elapsed=*)        set_elapsed="${1#*=}"; interactive=0 ;;
      --enabled=*)        set_enabled="${1#*=}";  interactive=0 ;;
      --date-rollover=*)  set_rollover="${1#*=}"; interactive=0 ;;
      --slow-after=*)     set_slow="${1#*=}";      interactive=0 ;;
      --slow-color=*)     set_slowcolor="${1#*=}"; interactive=0 ;;
      --idle-after=*)     set_idle="${1#*=}";      interactive=0 ;;
      --summary=*)        set_summary="${1#*=}";   interactive=0 ;;
      --subagents=*)      set_subagents="${1#*=}"; interactive=0 ;;
      --tool-timing=*)    set_tooltiming="${1#*=}"; interactive=0 ;;
      --history=*)        set_history="${1#*=}"; interactive=0 ;;
      --history-limit=*)  set_historylimit="${1#*=}"; interactive=0 ;;
      --inject-context=*) set_inject="${1#*=}";  interactive=0 ;;
      --show)             action="show"; interactive=0 ;;
      --doctor)           action="doctor"; interactive=0 ;;
      --stats)            action="stats"; interactive=0 ;;
      -h|--help)          usage; exit 0 ;;
      *) echo "Unknown argument: $1" >&2; echo >&2; usage >&2; exit 2 ;;
    esac
    shift
  done

  if [ "$action" = "show" ]; then show_config; exit 0; fi
  if [ "$action" = "doctor" ]; then doctor; exit $?; fi
  if [ "$action" = "stats" ]; then stats; exit $?; fi
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
  # A bare --marker= is unlike a bare --time-color=: an empty template is
  # already a legal, meaningful value (ct_is_valid_marker accepts it, and a
  # marker that renders empty emits no prefix at all), so it is honoured
  # rather than rejected -- the same way --tz=local sets an empty TZ.
  if [ "$marker_named" = "1" ]; then valid_marker "$set_marker" || exit 2; CT_MARKER_TEMPLATE="$set_marker"; fi
  apply_part_color "--time-color"    "$timecolor_named"    "$set_timecolor"    CT_TIME_COLOR
  apply_part_color "--elapsed-color" "$elapsedcolor_named" "$set_elapsedcolor" CT_ELAPSED_COLOR
  apply_part_color "--tool-color"    "$toolcolor_named"    "$set_toolcolor"    CT_TOOL_COLOR
  if [ -n "$set_elapsed" ]; then valid_onoff ELAPSED "$set_elapsed" || exit 2; CT_ELAPSED="$set_elapsed"; fi
  if [ -n "$set_inject" ];  then valid_bool INJECT_CONTEXT "$set_inject" || exit 2; CT_INJECT_CONTEXT="$set_inject"; fi
  if [ -n "$set_rollover" ]; then valid_onoff DATE_ROLLOVER "$set_rollover" || exit 2; CT_DATE_ROLLOVER="$set_rollover"; fi
  if [ -n "$set_slow" ]; then valid_seconds SLOW_AFTER "$set_slow" || exit 2; CT_SLOW_AFTER="$set_slow"; fi
  if [ -n "$set_idle" ]; then valid_seconds IDLE_AFTER "$set_idle" || exit 2; CT_IDLE_AFTER="$set_idle"; fi
  if [ -n "$set_slowcolor" ]; then valid_color "$set_slowcolor" || exit 2; CT_SLOW_COLOR="$set_slowcolor"; fi
  if [ -n "$set_summary" ]; then valid_onoff SUMMARY "$set_summary" || exit 2; CT_SUMMARY="$set_summary"; fi
  if [ -n "$set_subagents" ]; then valid_onoff SUBAGENTS "$set_subagents" || exit 2; CT_SUBAGENTS="$set_subagents"; fi
  if [ -n "$set_tooltiming" ]; then valid_onoff TOOL_TIMING "$set_tooltiming" || exit 2; CT_TOOL_TIMING="$set_tooltiming"; fi
  if [ -n "$set_history" ]; then valid_onoff HISTORY "$set_history" || exit 2; CT_HISTORY="$set_history"; fi
  if [ -n "$set_historylimit" ]; then valid_seconds HISTORY_LIMIT "$set_historylimit" || exit 2; CT_HISTORY_LIMIT="$set_historylimit"; fi
  if [ -n "$set_enabled" ]; then valid_onoff ENABLED "$set_enabled" || exit 2; CT_ENABLED="$set_enabled"; fi

  if [ "$project_scope" = "1" ]; then
    write_project_config "$set_tz" "$set_display" "$set_context" "$set_color" \
      "$set_elapsed" "$set_inject" "$set_rollover" "$set_slow" "$set_slowcolor" \
      "$set_idle" "$set_summary" "$set_subagents" "$set_tooltiming" "$set_enabled" \
      "$set_marker" "$set_timecolor" "$set_elapsedcolor" "$set_toolcolor" \
      "$set_history" "$set_historylimit" "$marker_named"
  else
    write_config
  fi
  echo -n "Preview: "; preview
  echo "Takes effect on the next message."
}

main "$@"
