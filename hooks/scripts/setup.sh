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

# Report filters for --stats, set by --since and --project in main()'s parser.
# Empty means unfiltered. These configure a report rather than a persisted
# setting, so they live here rather than in CT_FLAG_TABLE.
CT_STATS_SINCE=""
CT_STATS_PROJECT=""

usage() {
  cat <<'USAGE'
claude-timestamp setup

  setup.sh                    Interactive wizard.
  setup.sh [flags]            Write settings without prompting.
  setup.sh --show             Print the current configuration.
  setup.sh --doctor           Check that everything needed is present and working.
  setup.sh --stats            Summarise the sessions recorded so far.
  setup.sh --stats --since=7d  Only sessions from the last seven days.
  setup.sh --stats --since=2026-09-01
                              Only sessions on or after that date.
  setup.sh --stats --project=NAME
                              Only sessions recorded against that project.

Flags
  --tz=ZONE                   IANA timezone (Europe/Amsterdam), or "local".
  --display=FORMAT            24h | short | 12h | iso | any strftime string.
  --context=FORMAT            Same values; used for the model-facing time.
  --color=COLOR               none | dim | gray | cyan | blue | green
                              | yellow | magenta | red.
  --marker=TEMPLATE           The marker's layout. %time %elapsed %tool %date
                              are the parts; a {...} group holds at least one
                              of them and disappears when every part inside it
                              is empty.
  --time-color=COLOR          Colour of %time and %date. inherit follows
                              --color, which is also the default.
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
  --projects=on|off           Record the project's directory name in each
                              history row. Off by default. Never a path.
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

# --- the flag table ---------------------------------------------------------
#
# One row per setting, and the only place a flag's name, the key it writes, the
# variable it loads into, the validator it has to pass, its sentinel word and
# its empty-value policy are written down.
#
# This is what stops a setting being added without its validation. Every flag
# used to be parsed into a local of its own and then applied by a hand-written
# `if` that had to remember to call a validator -- and two of them, --display
# and --context, did not, which put an unvalidated value straight into the
# config file and let a newline in one write a second setting nobody named. The
# key list was also spelled out four more times: in main's locals, in
# write_project_config's twenty-one positional parameters, in the `set --` that
# re-paired them with their names on arrival, and in the `known` string beside
# it. Five copies of one list is five places to forget.
#
# The table is here rather than read out of schema.json because setup.sh must
# work on a machine with no jq -- that is the machine --doctor exists to
# diagnose. tools/check-docs.sh asserts every row against schema.json instead,
# so a row naming the wrong validator, or a schema key with no row, fails CI.
#
# The empty policy is what a flag given as `--x=` with nothing after it means:
#   ignore  not named at all, which is what every flag but the four below did
#   value   a real empty value; an empty MARKER is legal and renders no prefix
#   error   refused, because this flag's empty value already means "inherit"
CT_FLAG_TABLE="
enabled         ENABLED         CT_ENABLED          ct_is_onoff             -        ignore
tz              TZ              CT_TZ               ct_is_valid_tz          local    ignore
display         DISPLAY_FORMAT  CT_DISPLAY_FORMAT   ct_is_valid_format      -        ignore
context         CONTEXT_FORMAT  CT_CONTEXT_FORMAT   ct_is_valid_format      -        ignore
color           COLOR           CT_COLOR            ct_is_valid_color       -        ignore
marker          MARKER          CT_MARKER_TEMPLATE  ct_is_valid_marker      -        value
time-color      TIME_COLOR      CT_TIME_COLOR       ct_is_valid_part_color  inherit  error
elapsed-color   ELAPSED_COLOR   CT_ELAPSED_COLOR    ct_is_valid_part_color  inherit  error
tool-color      TOOL_COLOR      CT_TOOL_COLOR       ct_is_valid_part_color  inherit  error
elapsed         ELAPSED         CT_ELAPSED          ct_is_onoff             -        ignore
slow-after      SLOW_AFTER      CT_SLOW_AFTER       ct_is_seconds           -        ignore
slow-color      SLOW_COLOR      CT_SLOW_COLOR       ct_is_valid_color       -        ignore
idle-after      IDLE_AFTER      CT_IDLE_AFTER       ct_is_seconds           -        ignore
date-rollover   DATE_ROLLOVER   CT_DATE_ROLLOVER    ct_is_onoff             -        ignore
summary         SUMMARY         CT_SUMMARY          ct_is_onoff             -        ignore
subagents       SUBAGENTS       CT_SUBAGENTS        ct_is_onoff             -        ignore
tool-timing     TOOL_TIMING     CT_TOOL_TIMING      ct_is_onoff             -        ignore
history         HISTORY         CT_HISTORY          ct_is_onoff             -        ignore
history-limit   HISTORY_LIMIT   CT_HISTORY_LIMIT    ct_is_history_limit     -        ignore
projects        PROJECTS        CT_PROJECTS         ct_is_onoff             -        ignore
inject-context  INJECT_CONTEXT  CT_INJECT_CONTEXT   ct_is_bool              -        ignore
"

# --- validation -------------------------------------------------------------
# Each validator prints nothing on success and an explanation on failure, so a
# bad flag from the slash command produces a message worth relaying.
#
# The message belongs to the validator rather than to the flag, so the wizard
# and the flag path say the same thing about the same value. $2 is what to call
# the setting in the message: a flag as the user typed it, or a key name.

_ct_say_invalid() {
  local validator="$1" label="$2" value="$3"
  case "$validator" in
    ct_is_onoff)
      echo "$label must be 'on' or 'off', got '$value'." >&2 ;;
    ct_is_bool)
      echo "$label must be 'true' or 'false', got '$value'." >&2 ;;
    ct_is_seconds)
      echo "$label must be a whole number of seconds, got '$value'." >&2 ;;
    ct_is_history_limit)
      echo "$label must be a whole number of 1 or more, got '$value'." >&2
      echo "To keep no history at all, use --history=off." >&2 ;;
    ct_is_valid_color)
      echo "Unknown color '$value'. Pick: none dim gray red green yellow blue magenta cyan." >&2 ;;
    ct_is_valid_part_color)
      echo "Unknown colour '$value'. Pick: none dim gray red green yellow blue magenta cyan, or 'inherit' to follow --color." >&2 ;;
    ct_is_valid_format)
      echo "$label must be 24h, short, 12h, iso, or a strftime string containing %, got '$value'." >&2 ;;
    ct_is_valid_marker)
      echo "That marker template is not usable. The parts are %time, %elapsed, %tool and %date," >&2
      echo "a {...} group holds at least one of them and disappears when every part inside it is" >&2
      echo "empty, and braces must balance." >&2 ;;
    ct_is_valid_tz)
      echo "Timezone must be an IANA name like Europe/Amsterdam." >&2 ;;
    *)
      echo "$label does not accept '$value'." >&2 ;;
  esac
}

valid_tz() {
  local tz="$1"
  [ "$tz" = "local" ] && return 0
  [ -z "$tz" ] && return 0
  if ! ct_is_valid_tz "$tz"; then
    _ct_say_invalid ct_is_valid_tz timezone "$tz"
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
  _ct_say_invalid ct_is_valid_color color "$1"
  return 1
}

valid_marker() {
  ct_is_valid_marker "$1" && return 0
  _ct_say_invalid ct_is_valid_marker marker "$1"
  return 1
}

valid_seconds() {
  ct_is_seconds "$2" && return 0
  _ct_say_invalid ct_is_seconds "$1" "$2"
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

  local n total turns waited idle failed maxd maxwhen maxturns first last bad
  read -r n total turns waited idle failed maxd maxwhen maxturns first last bad <<EOF
$(awk -F'\t' -v since="${CT_STATS_SINCE:-}" -v want="${CT_STATS_PROJECT:-}" '
  # Six to eight fields, the last two being optional columns a row carries
  # only when the setting that fills them was on. Widening the count alone
  # would weaken the check, so the timings are checked for being timings:
  # a partially written line usually still lands on some field count, and
  # only this catches that.
  NF < 6 || NF > 8 { bad++; next }
  $2 !~ /^[0-9]+$/ || $3 !~ /^[0-9]+$/ || $4 !~ /^[0-9]+$/ ||
  $5 !~ /^[0-9]+$/ || $6 !~ /^[0-9]+$/ { bad++; next }
  # Filtered rows are skipped, not counted as unreadable: they were read
  # fine, they simply fall outside what was asked for.
  since != "" && $1 "" < since "" { next }
  want  != "" && ((NF >= 7 && $7 != "" ? $7 : "-") != want) { next }
  {
    n++; total += $2; turns += $3; waited += $4; idle += $5; failed += $6
    # Seeded on the first row rather than only when a row beats the running
    # maximum. A history whose longest session is zero seconds never satisfies
    # the comparison, so maxwhen stayed unset, its %s below printed nothing,
    # and the line came back one field short -- shifting every field after it
    # left, so maxturns became a date, last became "0", and bad came back
    # empty, which put a raw shell error in front of the user.
    # Seeded on the row count rather than on maxwhen still being empty. A row
    # whose date field is empty leaves maxwhen empty, so that test stayed true
    # and every later row re-seeded the maximum: a history whose longest
    # session carried no date reported the final duration as the longest one.
    if (n == 1 || $2 + 0 > maxd + 0) { maxd = $2; maxwhen = $1; maxturns = $3 }
    if (n == 1) first = $1
    last = $1
  }
  END {
    if (n == 0) { printf "0 0 0 0 0 0 0 - 0 - - %d\n", bad + 0; exit }
    # A hand-edited row can carry six fields and still have an empty date, and
    # an empty %s here would print two spaces where the reader expects one.
    # read collapses those, shifting every field after it left, which is the
    # same wrong-totals-and-a-raw-shell-error the NF check above exists to
    # prevent. "-" is what the no-rows line above already prints in these three
    # positions, so the reader needs nothing new to understand it.
    if (maxwhen == "") maxwhen = "-"
    if (first == "") first = "-"
    if (last == "") last = "-"
    printf "%d %d %d %d %d %d %d %s %d %s %s %d\n",
      n, total, turns, waited, idle, failed, maxd, maxwhen, maxturns, first, last, bad + 0
  }' "$file")
EOF

  if [ "$n" -eq 0 ]; then
    if [ -n "${CT_STATS_PROJECT:-}${CT_STATS_SINCE:-}" ]; then
      # The filter is named even though nothing matched. --since=7d resolves to
      # a date the user never typed, and "nothing matched" without saying what
      # was asked for leaves them unable to tell a wrong filter from an empty
      # history.
      printf 'No sessions match'
      [ -n "${CT_STATS_PROJECT:-}" ] && printf ' in %s' "$CT_STATS_PROJECT"
      [ -n "${CT_STATS_SINCE:-}" ] && printf ' since %s' "$CT_STATS_SINCE"
      printf '.\n'
      local known
      known="$(awk -F'\t' 'NF >= 7 && $7 != "" && $7 != "-" { print $7 }' "$file" \
               | sort -u | tr '\n' ' ')"
      [ -n "$known" ] && echo "  projects recorded: $known"
      return 0
    fi
    echo "No readable sessions recorded."
    [ "$bad" -gt 0 ] && echo "  $bad unreadable row(s) in $(ct_tilde "$file")."
    return 0
  fi

  # "last N sessions" is right for an unfiltered view and wrong for a filtered
  # one: the rows are the ones that matched, not the most recent ones. The
  # filter is spelled out so a narrowed total is never read as an all-time one.
  printf 'claude-timestamp stats%*s' "$((28 - 21))" ""
  if [ -n "${CT_STATS_SINCE:-}${CT_STATS_PROJECT:-}" ]; then
    printf '%s session' "$n"
  else
    printf 'last %s session' "$n"
  fi
  [ "$n" -eq 1 ] || printf 's'
  [ -n "${CT_STATS_PROJECT:-}" ] && printf ' in %s' "$CT_STATS_PROJECT"
  [ -n "${CT_STATS_SINCE:-}" ] && printf ' since %s' "$CT_STATS_SINCE"
  printf '\n\n'

  echo "  sessions        $n"
  [ "$bad" -gt 0 ] && echo "  $bad unreadable row(s) skipped; the file may have been edited by hand"
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

  # By project. Emitted only when at least one row named one, so an
  # installation that never turned PROJECTS on sees the output it saw before
  # the column existed.
  local rows
  rows="$(awk -F'\t' -v since="${CT_STATS_SINCE:-}" -v want="${CT_STATS_PROJECT:-}" '
    # The same validity test the totals above use, not a looser one. A row
    # rejected there and accepted here would put seconds into a per-project
    # figure that the total it sits under does not count, so the breakdown
    # would exceed the whole.
    NF < 6 || NF > 8 { next }
    $2 !~ /^[0-9]+$/ || $3 !~ /^[0-9]+$/ || $4 !~ /^[0-9]+$/ ||
    $5 !~ /^[0-9]+$/ || $6 !~ /^[0-9]+$/ { next }
    since != "" && $1 "" < since "" { next }
    want  != "" && ((NF >= 7 && $7 != "" ? $7 : "-") != want) { next }
    {
      # seen tracks whether any row named a real project, not merely whether
      # field 7 is present: a history where PROJECTS was never turned on, or
      # where TOOL_TIMING alone put a "-" placeholder in field 7 to hold its
      # place, must show no block at all -- (unnamed) only belongs to a mixed
      # history where at least one row names a project and another does not.
      named = (NF >= 7 && $7 != "" && $7 != "-")
      p = (NF >= 7 && $7 != "") ? $7 : "-"
      if (named) seen = 1
      secs[p] += $2; n[p]++
    }
    END {
      if (!seen) exit 0
      for (p in secs) printf "%018d\t%s\t%d\n", secs[p], p, n[p]
    }' "$file" | sort -rn)"
  if [ -n "$rows" ]; then
    echo
    echo "  by project"
    local p_secs p_name p_n label
    while IFS=$'\t' read -r p_secs p_name p_n; do
      [ -n "$p_name" ] || continue
      label="$p_name"
      [ "$label" = "-" ] && label="(unnamed)"
      printf '    %-20s %10s  %d session' "$label" \
        "$(ct_format_duration "$((10#$p_secs))")" "$p_n"
      [ "$p_n" -eq 1 ] || printf 's'
      printf '\n'
    done <<ROWS
$rows
ROWS
  fi

  # Slowest tools, summed across every recorded session. The per-session
  # summary answers "what made this session slow"; this answers "what has been
  # costing me", which is the question a hundred rows can answer and one
  # cannot.
  rows="$(awk -F'\t' -v since="${CT_STATS_SINCE:-}" -v want="${CT_STATS_PROJECT:-}" '
    # The same shared validity guard as the other two passes, plus one more
    # rule this pass alone needs: field 8 must actually be present, since a
    # row can be valid by the shared guard and still carry no tool digest.
    NF < 6 || NF > 8 { next }
    $2 !~ /^[0-9]+$/ || $3 !~ /^[0-9]+$/ || $4 !~ /^[0-9]+$/ ||
    $5 !~ /^[0-9]+$/ || $6 !~ /^[0-9]+$/ { next }
    since != "" && $1 "" < since "" { next }
    want  != "" && ((NF >= 7 && $7 != "" ? $7 : "-") != want) { next }
    NF < 8 || $8 == "" { next }
    {
      c = split($8, entries, ",")
      for (i = 1; i <= c; i++) {
        if (split(entries[i], part, ":") != 3) continue
        if (part[2] !~ /^[0-9]+$/ || part[3] !~ /^[0-9]+$/) continue
        secs[part[1]] += part[2]; calls[part[1]] += part[3]
      }
    }
    END { for (t in secs) printf "%018d\t%s\t%d\n", secs[t], t, calls[t] }
    ' "$file" | sort -rn | head -10)"
  if [ -n "$rows" ]; then
    echo
    echo "  slowest tools"
    local t_secs t_name t_calls
    while IFS=$'\t' read -r t_secs t_name t_calls; do
      [ -n "$t_name" ] || continue
      printf '    %-20s %10s  (%d call' "$t_name" \
        "$(ct_format_duration "$((10#$t_secs))")" "$t_calls"
      [ "$t_calls" -eq 1 ] || printf 's'
      printf ')\n'
    done <<ROWS
$rows
ROWS
  fi

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
  elif [ -n "${CT_PROJECT_SEARCH_CAPPED:-}" ]; then
    echo "  project file    none found, but the search stopped after 40 levels"
    echo "                  rather than reaching the top, so one further up was"
    echo "                  not looked at."
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
  # Computed before the echo rather than inside it. bash 3.2, which is what
  # macOS ships, cannot parse a `case` inside $( ): the first unparenthesised
  # `)` in a pattern closes the substitution instead of ending the pattern, and
  # the whole file then fails to parse. Every flag in this script died on it.
  local entry_note=""
  case "${CLAUDE_CODE_ENTRYPOINT-cli}" in
    cli) ;;
    *) { [ -n "${NO_COLOR:-}" ] || [ -n "${FORCE_COLOR:-}" ]; } ||
         entry_note=" (colour suppressed: not a terminal session)" ;;
  esac
  echo "  entrypoint      ${CLAUDE_CODE_ENTRYPOINT:-<unset>}$entry_note"

  # Whether a marker has ever actually reached the screen from this client.
  # Everything else here describes what the plugin intends to draw; this is the
  # only line that reports what it has drawn, which is the difference between
  # an install to repair and a client discarding what it was handed.
  local drawn_file drawn_at drawn_age drawn_now
  drawn_file="$(ct_drawn_path)"
  drawn_at=""
  [ -r "$drawn_file" ] && drawn_at="$(cat "$drawn_file" 2>/dev/null)"
  case "$drawn_at" in
    "" | *[!0-9]*)
      echo "  marker drawn    never from this client ($(ct_client_key))"
      echo "                  markers appear as messages are displayed, so a"
      echo "                  session that has shown none yet is expected here"
      ;;
    *)
      # An age needs both ends. ct_epoch reports 0 when `date` cannot be
      # reached, and subtracting a real time from that gives a large negative
      # number that the clamp below would report as "0s ago" -- the most
      # reassuring answer possible at the one moment nothing is known. Say so
      # instead. The clamp still stands for the case it was written for, a
      # clock that stepped backwards over a record made moments ago.
      drawn_now="$(ct_epoch)"
      if [ "$drawn_now" = "0" ]; then
        echo "  marker drawn    time unknown: this client has drawn, but the"
        echo "                  clock cannot be read to say how long ago"
      else
        drawn_age=$(( drawn_now - drawn_at ))
        [ "$drawn_age" -lt 0 ] && drawn_age=0
        # ct_format_duration, not ct_format_elapsed: the latter prefixes a "+"
        # because it renders a turn's length, and "+3s ago" reads as neither.
        echo "  marker drawn    $(ct_format_duration "$drawn_age") ago from this client ($(ct_client_key))"
      fi
      ;;
  esac
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
  if ct_state_ready; then
    echo "  directory       $dir (writable)"
  else
    echo "  directory       $dir NOT USABLE - missing, a symlink, not"
    echo "                  writable, or owned by another user. Elapsed time"
    echo "                  and the summary will not work."
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

# Render one value for the config file.
#
# The parser trims whitespace and unwraps a matching pair of quotes, which
# makes quoting the escape mechanism for a value whose own edges matter. A
# marker ending in a space is the case that needs it: it is legal, meaningful,
# and used to come back one character shorter than it went in.
conf_value() {
  local v="${1:-}"
  case "$v" in
    ''|*[!\ ]*)
      case "$v" in
        ' '*|*' '|\"*|\'*) printf "'%s'" "$v" ;;
        *)                 printf '%s' "$v" ;;
      esac
      ;;
    *) printf "'%s'" "$v" ;;
  esac
}

# Write a file by building it beside the target and renaming over it.
#
# ct_load_config reads the config from five hooks, and message-display reads it
# on every displayed message, so a writer that truncates in place can be caught
# mid-write: the reader sees a partial file and silently falls back to defaults
# for the keys not written yet. Rename is atomic on every filesystem this runs
# on, so a reader sees either the whole old file or the whole new one. Same
# shape ct_write_facts and ct_history_append already use.
#
# The temp file sits beside the target rather than in a temp directory, because
# a rename across filesystems is not atomic and is not even the same syscall.
# That is also why the link is resolved before the temp name is chosen: the
# file a link names can live on another filesystem than the link itself.
#
# A symlinked target is followed to the file it names rather than renamed over.
# Renaming replaces the name, so an unresolved link is itself replaced by a
# regular file: the wizard reports success, and the file the link pointed at
# keeps the old settings until the next relink throws the new ones away.
# Symlinking the config into a dotfiles repository is the ordinary way to
# version it, so that detachment is silent and costs the user their settings.
#
# readlink -f resolves a chain in one call but is GNU-only, and this has to run
# on macOS and Git Bash, so the chain is walked here. A relative target is
# relative to the directory the link sits in. The hop limit ends a symlink
# loop; a target still unresolved after it is refused rather than written over,
# because writing at that point would replace the last link in the loop.
_ct_write_atomic() {
  local file="$1" tmp target hops=0
  while [ -L "$file" ]; do
    if [ "$hops" -ge 40 ]; then return 1; fi
    target="$(readlink "$file")" || return 1
    case "$target" in
      /*) file="$target" ;;
      *)  case "$file" in
            */*) file="${file%/*}/$target" ;;
            *)   file="$target" ;;
          esac ;;
    esac
    hops=$((hops + 1))
  done
  tmp="$file.$$"
  cat > "$tmp" || { rm -f "$tmp" 2>/dev/null; return 1; }
  mv "$tmp" "$file" || { rm -f "$tmp" 2>/dev/null; return 1; }
  return 0
}

write_config() {
  local file dir
  file="$(ct_config_path)"
  dir="$(dirname "$file")"
  mkdir -p "$dir"
  _ct_write_atomic "$file" <<CONF
# claude-timestamp configuration
# Written by setup.sh -- safe to edit by hand. Run /timestamps to change it
# interactively. Unknown keys are ignored.

# Master switch. off silences every hook without uninstalling the plugin.
ENABLED=$CT_ENABLED

# IANA timezone name, or empty for the machine's local time.
TZ=$(conf_value "$CT_TZ")

# 24h | short | 12h | iso, or any strftime string (anything with a % in it).
DISPLAY_FORMAT=$(conf_value "$CT_DISPLAY_FORMAT")
CONTEXT_FORMAT=$(conf_value "$CT_CONTEXT_FORMAT")

# none dim gray red green yellow blue magenta cyan. NO_COLOR also disables it.
COLOR=$CT_COLOR

# The marker's layout. %time %elapsed %tool %date are the parts, and a {...}
# group disappears when every part inside it is empty.
MARKER=$(conf_value "$CT_MARKER_TEMPLATE")

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
  local file dir key value existing out="" named line ekey known="" carried pair
  local t_flag t_key t_var t_validator t_sentinel t_empty
  # $PWD/.claude/claude-timestamp.conf is the account config when $PWD is the
  # home directory, and ct_find_project_config refuses to read that file as a
  # project layer. Writing it here would produce a file that calls itself a
  # project config, is never loaded as one, and has lost every comment in the
  # account config it replaced.
  #
  # Compared two ways, and refused if either matches. Physically-resolved
  # paths catch a symlinked home; the raw strings are a fail-safe for the
  # asymmetric case where resolving $HOME fails (permissions, a dangling
  # symlink) while resolving $PWD does not -- a resolved-only comparison would
  # then compare a real path against a stale fallback and could miss a literal
  # match it would otherwise have caught. Refusing a legitimate project write
  # costs a re-run; missing home costs silently rewriting the account config,
  # so the fail-safe direction is to refuse.
  local here here_home
  here="$(cd "$PWD" 2>/dev/null && pwd -P)" || here="$PWD"
  here_home="$(cd "${HOME:-}" 2>/dev/null && pwd -P)" || here_home="${HOME:-}"
  if [ -n "${HOME:-}" ] && { [ "$here" = "$here_home" ] || [ "$PWD" = "$HOME" ]; }; then
    echo "--project writes .claude/claude-timestamp.conf in the current directory," >&2
    echo "and here that is your account configuration, not a project's. Run it from" >&2
    echo "a project directory, or drop --project to change your account settings." >&2
    return 2
  fi
  file="$PWD/$CT_CONFIG_NAME"
  dir="$(dirname "$file")"
  mkdir -p "$dir"

  existing=""
  [ -r "$file" ] && existing="$(cat "$file")"

  # "$@" is KEY=value for every setting named on this run, already
  # sentinel-resolved by main. Presence in that list IS "was it named", which
  # is what the twenty-one positional parameters and a separate marker_named
  # flag used to encode -- MARKER needed one because its legitimately-named
  # value can itself be the empty string, and an empty slot could not tell that
  # apart from "not named".
  named=""
  for pair in "$@"; do
    named="${named}|${pair%%=*}|"
  done

  # Walked in table order, so the table decides the file's layout too and the
  # list of keys this function knows about is not a fifth copy of one.
  # shellcheck disable=SC2034  # the trailing columns are read to consume the
  # line; only the flag and the key matter to this writer.
  while read -r t_flag t_key t_var t_validator t_sentinel t_empty; do
    [ -n "$t_flag" ] || continue
    key="$t_key"
    known="${known}${key}|"

    value=""
    carried=0
    case "$named" in
      *"|${key}|"*)
        for pair in "$@"; do
          [ "${pair%%=*}" = "$key" ] && value="${pair#*=}"
        done
        ;;
      *)
        # Not named now. Keep it only if this project already pinned it -- and
        # test that by whether the key is present in the file, not by whether
        # the value that comes back is empty. Both an absent key and a key
        # pinned to the empty string (TZ=, or a colour set to inherit) extract
        # as "", so emptiness alone cannot tell "nothing to keep" from "keep an
        # empty pin"; presence can.
        if printf '%s\n' "$existing" | grep -q "^${key}="; then
          value="$(printf '%s\n' "$existing" | sed -n "s/^${key}=//p" | tail -1)"
          carried=1
        else
          continue
        fi
        ;;
    esac

    # A carried value is raw text lifted verbatim out of the existing file --
    # already in its written form, quotes and all. Serialising it again is how
    # one quote pair becomes two, then three on the next unrelated write. Only
    # a value that came from a flag this run is still semantic and needs
    # conf_value to render it.
    if [ "$carried" = "1" ]; then
      out="${out}${key}=${value}
"
    else
      out="${out}${key}=$(conf_value "$value")
"
    fi
  done <<TABLE
$CT_FLAG_TABLE
TABLE
  known="|${known}"

  # A key this run does not recognise -- one a newer version of the plugin
  # wrote -- is carried over unchanged rather than dropped. lib/config.sh
  # promises that a config a newer version writes stays readable by an older
  # one; silently losing such a key the next time this (older) setup.sh
  # rewrites the file would break that promise the moment the file is
  # written, not merely read.
  if [ -n "$existing" ]; then
    while IFS= read -r line; do
      case "$line" in
        '') continue ;;
        '#'*)
          # A comment somebody wrote by hand is theirs, not ours to drop.
          # Skipped only when it is one of the three this function writes.
          case "$line" in
            '# claude-timestamp settings for this project'|\
            '# Layered over your own configuration, which still supplies everything'|\
            '# not listed here. Run /timestamps to change it.') continue ;;
          esac
          out="${out}${line}
"
          continue
          ;;
        *=*) ekey="${line%%=*}" ;;
        *)   continue ;;
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
  } | _ct_write_atomic "$file"
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
    # Try -f first, fall back to a plain read. -f resolves a chain of symlinks
    # and any relative component to a canonical path; a plain readlink returns
    # only the immediate target. On Linux, /etc/localtime is sometimes a chain,
    # and dropping -f outright would silently stop detecting the zone there.
    # BSD readlink before macOS 12.3 has no -f at all, so it needs the plain
    # read. Trying both is two lines and strictly better than either alone:
    # each failure degrades to an empty result, which is the same "could not
    # detect" the wizard already handles.
    local target
    target="$(readlink -f /etc/localtime 2>/dev/null)" || target=""
    [ -n "$target" ] || target="$(readlink /etc/localtime 2>/dev/null)" || target=""
    case "$target" in "$ZONEINFO"/*) printf '%s' "${target#"$ZONEINFO"/}"; return ;; esac
  fi
  printf ''
}

# Ask one question, into _CT_ANSWER.
#
# Assigns rather than printing because every caller used to write
# answer="$(ask ...)", which runs this in a subshell -- and CT_ASK_EOF, set
# here when input runs out, never reached the caller. Every re-ask loop's
# escape hatch was therefore dead code, and the wizard spun forever whenever
# the default it kept offering was itself invalid.
#
# The same assign-don't-print shape ct_paint_part uses, for the same reason:
# a subshell loses what the caller needs.
ask() {
  local prompt="$1" default="$2" answer
  if [ -t 0 ]; then
    # Interactive: read the terminal directly, so the wizard still works when
    # something has redirected this script's stdin.
    if ! read -r -p "$prompt [$default]: " answer </dev/tty; then
      answer=""
      CT_ASK_EOF=1
    fi
  else
    # No terminal, so answers are being piped in. Reading stdin here is what
    # makes the wizard testable without a pseudo-terminal.
    printf '%s [%s]: ' "$prompt" "$default" >&2
    if ! read -r answer; then
      answer=""
      # Input is exhausted. Without this the re-ask loops below would spin
      # forever on a value that never becomes valid.
      CT_ASK_EOF=1
    fi
  fi
  _CT_ANSWER="${answer:-$default}"
  return 0
}

wizard() {
  ct_load_config

  echo "claude-timestamp setup"
  echo "Press Enter to keep the value in brackets."
  echo

  local answer
  local tpl wp_time wp_el wp_tool
  local CT_ASK_EOF=""

  # Enabled
  echo "Master switch for the whole plugin. Off silences every hook without"
  echo "uninstalling it, and the rest of your settings stay put for next time."
  ask "Enable claude-timestamp? (on/off)" "$CT_ENABLED"; answer="$_CT_ANSWER"
  case "$answer" in on|off) CT_ENABLED="$answer" ;; esac
  echo

  # Timezone
  # The detected zone is a guess from the environment, not a validated setting,
  # so it can name something this machine cannot resolve. Offering it as the
  # default then means the wizard suggests an answer it will refuse, which on
  # exhausted stdin is a loop with no exit.
  local detected current
  detected="$(detect_tz)"
  if [ -n "$detected" ] && ! valid_tz "$detected" 2>/dev/null; then
    detected=""
  fi
  current="${CT_TZ:-${detected:-local}}"
  echo "Timezone. Type an IANA name (Europe/Amsterdam), or 'local' for this"
  echo "machine's own time. Type 'list' to search the installed zones."
  while :; do
    ask "  Timezone" "$current"; answer="$_CT_ANSWER"
    if [ "$answer" = "list" ]; then
      local term
      ask "  Search for" "Europe"; term="$_CT_ANSWER"
      if [ -d "$ZONEINFO" ]; then
        find "$ZONEINFO" -type f -path "*$term*" 2>/dev/null \
          | sed "s|^$ZONEINFO/||" | grep -v '^posix/\|^right/\|\.' | sort | head -25
      else
        echo "  No zoneinfo database on this machine; type the name directly."
      fi
      [ -n "${CT_ASK_EOF:-}" ] && break
      continue
    fi
    if valid_tz "$answer"; then
      [ "$answer" = "local" ] && CT_TZ="" || CT_TZ="$answer"
      break
    fi
    # Input is exhausted, so re-asking would spin forever on a value that can
    # never become valid. Every other question here breaks the same way.
    [ -n "${CT_ASK_EOF:-}" ] && break
  done
  echo

  # Display format
  echo "Clock format for the marker on screen."
  local fmt
  while :; do
    echo "  24h = $(ct_now 24h)   short = $(ct_now short)   12h = $(ct_now 12h)   iso = $(ct_now iso)"
    ask "  Display format" "$CT_DISPLAY_FORMAT"; fmt="$_CT_ANSWER"
    case "$fmt" in
      24h|short|12h|iso|*%*) CT_DISPLAY_FORMAT="$fmt"; break ;;
      *) echo "  Pick 24h, short, 12h, iso, or a strftime string containing %." ;;
    esac
    # Safe today because ct_validate_config guarantees the offered default
    # always matches this case, but the other re-ask loops carry this guard
    # too and there is no reason for this one to depend on a property that
    # lives in a different file.
    [ -n "${CT_ASK_EOF:-}" ] && break
  done
  echo

  # Elapsed
  ask "Show how long each turn took? (on/off)" "$CT_ELAPSED"; answer="$_CT_ANSWER"
  case "$answer" in on|off) CT_ELAPSED="$answer" ;; esac
  echo

  # Duration extras, only worth asking about when durations are shown at all.
  if [ "$CT_ELAPSED" = "on" ]; then
    while :; do
      ask "  Colour the duration after how many seconds? (0 = never)" "$CT_SLOW_AFTER"; answer="$_CT_ANSWER"
      if valid_seconds SLOW_AFTER "$answer"; then CT_SLOW_AFTER="$answer"; break; fi
      [ -n "${CT_ASK_EOF:-}" ] && break
    done
  fi
  while :; do
    ask "Mark a gap between messages after how many seconds? (0 = never)" "$CT_IDLE_AFTER"; answer="$_CT_ANSWER"
    if valid_seconds IDLE_AFTER "$answer"; then CT_IDLE_AFTER="$answer"; break; fi
    [ -n "${CT_ASK_EOF:-}" ] && break
  done
  ask "Report session totals when the session ends? (on/off)" "$CT_SUMMARY"; answer="$_CT_ANSWER"
  case "$answer" in on|off) CT_SUMMARY="$answer" ;; esac
  if [ "$CT_SUMMARY" = "on" ]; then
    echo "  Tool timing names the slowest tools in that summary. It is the only"
    echo "  setting that costs anything per tool call rather than per message."
    ask "  Record what each tool call cost? (on/off)" "$CT_TOOL_TIMING"; answer="$_CT_ANSWER"
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
    ask "  Color" "$CT_COLOR"; answer="$_CT_ANSWER"
    if valid_color "$answer"; then CT_COLOR="$answer"; break; fi
    [ -n "${CT_ASK_EOF:-}" ] && break
  done
  echo

  # The marker's layout. Shown as three real renderings rather than described,
  # because a template is much easier to recognise than to read.
  echo "The marker's layout is a template. %time %elapsed %tool %date are the"
  echo "parts, and a {...} group holds at least one of them and disappears when"
  echo "every part inside it is empty."
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
    ask "  Marker" "$CT_MARKER_TEMPLATE"; answer="$_CT_ANSWER"
    if valid_marker "$answer"; then CT_MARKER_TEMPLATE="$answer"; break; fi
    # Input is exhausted, so re-asking would spin forever on a value that can
    # never become valid. Every other question here breaks the same way.
    [ -n "${CT_ASK_EOF:-}" ] && break
  done
  echo

  # Model-facing context
  echo "Claude can also be told the local time each prompt was sent, so it can"
  echo "reason about when things happened. This costs a few tokens per message."
  ask "  Tell Claude the time? (true/false)" "$CT_INJECT_CONTEXT"; answer="$_CT_ANSWER"
  case "$answer" in true|false) CT_INJECT_CONTEXT="$answer" ;; esac
  if [ "$CT_INJECT_CONTEXT" = "true" ]; then
    while :; do
      ask "  Format Claude sees" "$CT_CONTEXT_FORMAT"; fmt="$_CT_ANSWER"
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
  ask "Write this configuration? (y/n)" "y"; answer="$_CT_ANSWER"
  case "$answer" in
    y|Y|yes) write_config; echo "This takes effect on your next message. No restart needed." ;;
    *) echo "Nothing written." ;;
  esac
}

# --- entry point ------------------------------------------------------------

# Look a row up in the table, into _CT_F_*. Returns 1 when there is no row.
_ct_flag_row() {
  local want="$1" flag key var validator sentinel empty
  while read -r flag key var validator sentinel empty; do
    [ -n "$flag" ] || continue
    [ "$flag" = "$want" ] || continue
    _CT_F_FLAG="$flag"; _CT_F_KEY="$key"; _CT_F_VAR="$var"
    _CT_F_VALIDATOR="$validator"; _CT_F_SENTINEL="$sentinel"; _CT_F_EMPTY="$empty"
    return 0
  done <<TABLE
$CT_FLAG_TABLE
TABLE
  return 1
}

# The same lookup by config key rather than by flag name. Two callers need it:
# main, to recover a row after parsing, and write_project_config, to walk the
# settings in table order.
_ct_flag_row_for_key() {
  local want="$1" flag key var validator sentinel empty
  while read -r flag key var validator sentinel empty; do
    [ -n "$flag" ] || continue
    [ "$key" = "$want" ] || continue
    _CT_F_FLAG="$flag"; _CT_F_KEY="$key"; _CT_F_VAR="$var"
    _CT_F_VALIDATOR="$validator"; _CT_F_SENTINEL="$sentinel"; _CT_F_EMPTY="$empty"
    return 0
  done <<TABLE
$CT_FLAG_TABLE
TABLE
  return 1
}

main() {
  local interactive=1 action="write" project_scope=0
  local arg flag value i
  # Parallel arrays with a counter of their own. bash 3.2 is what macOS ships:
  # it has no associative arrays, and under `set -u` it treats an empty array
  # as unset, so neither ${#arr[@]} nor a bare "${arr[@]}" is safe to lean on
  # there. A plain integer and the ${arr[@]+...} guard are.
  #
  # A key present in named_keys was named on this run, which is the whole of
  # what "named" used to need four separate *_named locals to express.
  local named_keys=() named_values=() named_count=0

  while [ $# -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --config=*)  CLAUDE_TIMESTAMP_CONFIG="${arg#*=}"; export CLAUDE_TIMESTAMP_CONFIG ;;
      --project)   project_scope=1; interactive=0 ;;
      --show)      action="show";   interactive=0 ;;
      --doctor)    action="doctor"; interactive=0 ;;
      --stats)     action="stats";  interactive=0 ;;
      --since=*)
        action="stats"; interactive=0
        value="${arg#*=}"
        case "$value" in
          [0-9]*d)
            CT_STATS_SINCE="$(ct_date_days_ago "${value%d}")" || {
              echo "This system's date cannot compute a cutoff. Use --since=YYYY-MM-DD." >&2
              exit 2
            } ;;
          [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9])
            CT_STATS_SINCE="$value" ;;
          *)
            echo "--since takes a number of days such as 7d, or a date such as 2026-09-01." >&2
            exit 2 ;;
        esac ;;
      --project=*)
        action="stats"; interactive=0
        CT_STATS_PROJECT="${arg#*=}" ;;
      -h|--help)   usage; exit 0 ;;
      --*=*)
        flag="${arg#--}"; flag="${flag%%=*}"
        value="${arg#*=}"
        if ! _ct_flag_row "$flag"; then
          echo "Unknown argument: $arg" >&2; echo >&2; usage >&2; exit 2
        fi
        interactive=0
        # An empty value means three different things depending on the flag,
        # and the table says which. Resolved here so everything downstream --
        # the validator, the writers, "was it named at all" -- sees one shape.
        if [ -z "$value" ]; then
          case "$_CT_F_EMPTY" in
            ignore) shift; continue ;;
            error)
              echo "--$flag needs a value: a colour name, or 'inherit' to follow --color." >&2
              exit 2
              ;;
          esac
        fi
        # The sentinel word is how a flag spells its empty value out loud:
        # --tz=local, --time-color=inherit. Both mean "write nothing here".
        [ "$_CT_F_SENTINEL" != "-" ] && [ "$value" = "$_CT_F_SENTINEL" ] && value=""

        # Validated as it is parsed, before anything is written, so a run that
        # names four settings and gets the third wrong changes none of them.
        # It also means no value reaching the arrays below has ever skipped its
        # validator, which is the property this table exists to guarantee.
        if ! "$_CT_F_VALIDATOR" "$value"; then
          _ct_say_invalid "$_CT_F_VALIDATOR" "--$flag" "$value"
          exit 2
        fi
        # TZ carries one check no other key needs and no validator can express:
        # whether this machine can resolve the zone at all. A platform without
        # a timezone database does not fail on an unknown name, it silently
        # renders UTC, so pinning a zone there would write a config that lies.
        if [ "$_CT_F_KEY" = "TZ" ] && [ -n "$value" ]; then
          valid_tz "$value" || exit 2
        fi

        named_keys[named_count]="$_CT_F_KEY"
        named_values[named_count]="$value"
        named_count=$(( named_count + 1 ))
        ;;
      *) echo "Unknown argument: $arg" >&2; echo >&2; usage >&2; exit 2 ;;
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

  # Apply after loading, or ct_load_config would overwrite what was named.
  local pairs=() pair_count=0
  i=0
  while [ "$i" -lt "$named_count" ]; do
    _ct_flag_row_for_key "${named_keys[$i]}" || exit 2
    printf -v "$_CT_F_VAR" '%s' "${named_values[$i]}"
    pairs[pair_count]="${named_keys[$i]}=${named_values[$i]}"
    pair_count=$(( pair_count + 1 ))
    i=$(( i + 1 ))
  done

  if [ "$project_scope" = "1" ]; then
    # write_project_config's return already exits the script under set -e with
    # the same code -- this changes no behaviour today. It is here so the
    # intent is explicit at the call site: if a later edit ever wraps this
    # call in a condition (an if, a &&, a while), errexit stops applying to it
    # silently, and the refusal's exit code would be lost without this.
    #
    # The ${pairs[@]+...} guard is what makes a run that named nothing safe on
    # bash 3.2, where an empty array under `set -u` aborts the plain form.
    write_project_config "${pairs[@]+"${pairs[@]}"}" || exit $?
  else
    write_config
  fi
  echo -n "Preview: "; preview
  echo "Takes effect on the next message."
}

main "$@"
