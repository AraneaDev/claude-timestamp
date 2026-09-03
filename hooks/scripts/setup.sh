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

# CLAUDE_TIMESTAMP_ZONEINFO exists so the test suite can point the wizard's
# zone search at a synthetic tree large enough to reproduce a SIGPIPE that a
# real machine's own zoneinfo may be too small to trigger; it is not a
# user-facing setting.
ZONEINFO="${CLAUDE_TIMESTAMP_ZONEINFO:-/usr/share/zoneinfo}"

# Report filters for --stats, set by --since and --project in main()'s parser.
# Empty means unfiltered. These configure a report rather than a persisted
# setting, so they live here rather than in CT_FLAG_TABLE.
#
# CT_STATS_SINCE_DAYS holds the day count from a relative --since=Nd until
# stats() can resolve it: the parser runs before ct_load_config, so CT_TZ is
# still empty there, and resolving the cutoff that early would render it in
# the machine's zone rather than the configured one. The absolute
# --since=YYYY-MM-DD form needs no such deferral -- it is a literal, so it
# goes straight into CT_STATS_SINCE.
CT_STATS_SINCE=""
CT_STATS_SINCE_DAYS=""
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

  # The relative --since form is stored as a day count rather than resolved
  # in the parser, because the parser runs before ct_load_config -- CT_TZ is
  # still empty there, so a cutoff computed at parse time would be rendered
  # in the machine's zone rather than the configured one. Resolved here,
  # right after the config (and therefore CT_TZ) is loaded.
  if [ -n "${CT_STATS_SINCE_DAYS:-}" ]; then
    CT_STATS_SINCE="$(ct_date_days_ago "$CT_STATS_SINCE_DAYS")" || {
      echo "This system's date cannot compute a cutoff. Use --since=YYYY-MM-DD." >&2
      return 2
    }
  fi

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
  # Bounded to 15 digits, not merely to digits. That still admits any real
  # duration -- 15 nines is over 31 million years of seconds -- while
  # keeping each individual value inside the exact-integer range of a
  # double (2^53 is 16 digits), so awk cannot silently round it, and inside
  # the 64-bit range of the shell downstream, where a longer run of digits
  # overflowed and turned every arithmetic expression that touched it into
  # a raw shell error. This bounds each value alone, not their sum: totals,
  # waited, idle, turns and failed below are accumulated across every
  # matching row, and a sum of many 15-digit values can still exceed the
  # 64-bit range of the shell even though every value that fed it
  # individually respected this bound. The END block below carries a
  # second bound for that accumulated case -- and so do the by-project and
  # slowest-tools passes further down, which accumulate the same kind of
  # per-row values into secs[] and calls[] of their own and are exposed to
  # exactly the same overflow.
  $2 !~ /^[0-9]{1,15}$/ || $3 !~ /^[0-9]{1,15}$/ || $4 !~ /^[0-9]{1,15}$/ ||
  $5 !~ /^[0-9]{1,15}$/ || $6 !~ /^[0-9]{1,15}$/ { bad++; next }
  # Field 1 (the date) is otherwise never validated, and it is emitted
  # through a bare %s into a space-separated line that a positional `read`
  # downstream consumes -- so a field 1 containing a space reads as extra
  # words, shifting every field after it left the same way an empty
  # maxwhen/first/last already does above, right down to the raw shell
  # error. Rejecting on whitespace specifically, not on a full ISO-8601
  # shape: ct_history_append always writes this field with `ct_now iso`,
  # so a stricter pattern would probably still be safe, but whitespace is
  # what actually breaks the reader, and the narrower rule cannot reject a
  # legitimate historical row written by an older or newer format.
  $1 ~ /[[:space:]]/ { bad++; next }
  # Filtered rows are skipped, not counted as unreadable: they were read
  # fine, they simply fall outside what was asked for.
  since != "" && $1 "" < since "" { next }
  want  != "" && ((NF >= 7 && $7 != "" ? $7 : "-") "" != want "") { next }
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
    # The per-value bound above keeps any one duration inside the 64-bit
    # range of the shell; it says nothing about their sum. Enough rows each
    # individually at that bound overflow these accumulators once awk sums
    # them as doubles -- past 2^53 the sum itself is no longer exact, and
    # the rounded result handed to the shell can land outside its signed
    # 64-bit range entirely, reproducing the same raw shell error
    # ("integer expression expected") the per-value bound exists to
    # prevent. Clamped here to a value comfortably under the shell limit of
    # INT64_MAX (about 9.22e18), with headroom for "waiting" below, which
    # multiplies its total by 100 before dividing: the cap on waited times
    # 100 must itself still fit, so the cap is chosen an order of magnitude
    # below the raw 64-bit ceiling rather than right up against it. Every
    # real history is many orders of magnitude under this either way --
    # 9e16 seconds is billions of years of sessions -- so the clamp is
    # unreachable in practice; it exists so the shell downstream is
    # mathematically guaranteed never to see an integer it cannot hold,
    # rather than relying on that being true by coincidence of scale.
    cap = 90000000000000000
    if (total  > cap) total  = cap
    if (waited > cap) waited = cap
    if (idle   > cap) idle   = cap
    if (turns  > cap) turns  = cap
    if (failed > cap) failed = cap
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
      # The same row-validity guard the totals, by-project and slowest-tools
      # passes above share -- NF in range, each timing field a bounded run of
      # digits, no whitespace in the date -- so this hint can only ever name
      # a project that those passes would themselves count. Without it, a
      # damaged row's field 7 could be offered as a suggestion and then
      # refused when the reader tried it, since --project filters against
      # the very same guard.
      #
      # It also carries the same `since` clause as those three passes, for a
      # different reason: this hint exists to point a reader at a project
      # they can actually retry, and a suggestion --since already excludes is
      # a dead end -- refused the moment it is tried, with no way to tell
      # that from a plain typo. It deliberately does NOT carry `want`: a
      # project filter with no matches is exactly why this hint runs, so
      # filtering the hint on that same project would empty it out.
      known="$(awk -F'\t' -v since="${CT_STATS_SINCE:-}" '
        NF < 6 || NF > 8 { next }
        $2 !~ /^[0-9]{1,15}$/ || $3 !~ /^[0-9]{1,15}$/ || $4 !~ /^[0-9]{1,15}$/ ||
        $5 !~ /^[0-9]{1,15}$/ || $6 !~ /^[0-9]{1,15}$/ { next }
        $1 ~ /[[:space:]]/ { next }
        since != "" && $1 "" < since "" { next }
        NF >= 7 && $7 != "" && $7 != "-" { print $7 }
      ' "$file" | sort -u | tr '\n' ' ')"
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
    # Same 15-digit bound as the totals pass, and for the same reason: a
    # value long enough to overflow the 64-bit arithmetic of the shell
    # downstream is damage, not a duration.
    $2 !~ /^[0-9]{1,15}$/ || $3 !~ /^[0-9]{1,15}$/ || $4 !~ /^[0-9]{1,15}$/ ||
    $5 !~ /^[0-9]{1,15}$/ || $6 !~ /^[0-9]{1,15}$/ { next }
    # Same whitespace-in-the-date-field guard as the totals pass, for the
    # same reason given there: a row rejected as damage by the totals must
    # not still count here, or the breakdown would exceed the whole.
    $1 ~ /[[:space:]]/ { next }
    since != "" && $1 "" < since "" { next }
    want  != "" && ((NF >= 7 && $7 != "" ? $7 : "-") "" != want "") { next }
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
      # Same accumulator-overflow bound as the totals pass above, applied per
      # project rather than once globally: secs[p] is summed across every row
      # naming project p, and enough rows at the per-value bound can carry
      # that projects sum past the 64-bit range of the shell downstream even
      # though no single value that fed it broke the per-value bound. Capped
      # per project, not on a grand total across projects, since the failure
      # this guards is a single accumulator overflowing on its own, not the
      # sum of all of them.
      cap = 90000000000000000
      for (p in secs) {
        if (secs[p] > cap) secs[p] = cap
        printf "%018d\t%s\t%d\n", secs[p], p, n[p]
      }
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
    # Same 15-digit bound as the totals pass, and for the same reason.
    $2 !~ /^[0-9]{1,15}$/ || $3 !~ /^[0-9]{1,15}$/ || $4 !~ /^[0-9]{1,15}$/ ||
    $5 !~ /^[0-9]{1,15}$/ || $6 !~ /^[0-9]{1,15}$/ { next }
    # Same whitespace-in-the-date-field guard as the totals pass, for the
    # same reason given there: a row rejected as damage by the totals must
    # not still count here.
    $1 ~ /[[:space:]]/ { next }
    since != "" && $1 "" < since "" { next }
    want  != "" && ((NF >= 7 && $7 != "" ? $7 : "-") "" != want "") { next }
    NF < 8 || $8 == "" { next }
    {
      c = split($8, entries, ",")
      for (i = 1; i <= c; i++) {
        if (split(entries[i], part, ":") != 3) continue
        # An empty name (a hand-edited ":0:1" entry) must not become a row.
        # The read loop below splits on \037 (unit separator), not tab, and
        # \037 is not one of the "IFS whitespace" characters, so `read`
        # preserves an empty field there instead of collapsing it into a
        # neighbour -- the collapse that would otherwise shift the call
        # count into the name and leave the count empty, failing an integer
        # test with a raw shell error. That means this skip is no longer
        # the thing standing between an empty name and that collapse; \037
        # already prevents it. This is defense in depth: it keeps an empty
        # name out of the emitted rows at all, the same way ct_tool_digest
        # in lib/config.sh already skips a malformed entry at the source.
        if (part[1] == "") continue
        # Same 15-digit bound as the timing fields of the row itself.
        if (part[2] !~ /^[0-9]{1,15}$/ || part[3] !~ /^[0-9]{1,15}$/) continue
        secs[part[1]] += part[2]; calls[part[1]] += part[3]
      }
    }
    # \037 (unit separator) rather than a tab: the read loop below uses
    # `read`, and tab is one of the "IFS whitespace" characters, which makes
    # `read` collapse adjacent delimiters and trim leading/trailing ones
    # regardless of what IFS is set to, so a field that really was empty
    # would silently shift into its neighbour. \037 is not whitespace to
    # `read`, so an empty field stays an empty field no matter what this
    # awk emits -- the entries loop above already keeps that from
    # happening, this just stops relying on it staying that way.
    END {
      # Same accumulator-overflow bound as the totals and by-project passes
      # above, applied per tool: secs[t] and calls[t] are each summed across
      # every occurrence of tool t, and enough occurrences at the per-value
      # bound can carry either sum past the 64-bit range of the shell
      # downstream even though no single value that fed it broke the
      # per-value bound. calls[t] gets the same cap as secs[t] for the same
      # reason, not because it feeds a multiplication like waited does above:
      # it reaches a plain `[ -eq ]` test in the shell, and an accumulator
      # that overflows there raises the identical raw "integer expression
      # expected" error.
      cap = 90000000000000000
      for (t in secs) {
        if (secs[t]  > cap) secs[t]  = cap
        if (calls[t] > cap) calls[t] = cap
        printf "%018d\037%s\037%d\n", secs[t], t, calls[t]
      }
    }
    ' "$file" | sort -rn | head -10)" || true
  # `|| true` above: on a history with many distinct tool names, `head -10`
  # closes the pipe once it has its ten lines, and `sort` -- which may still
  # have more to write -- gets SIGPIPE for it, even though every line `head`
  # needed had already been delivered. That makes the pipeline's exit status
  # nonzero for reasons that have nothing to do with the output being wrong.
  # `--stats` runs under this script's own errexit/pipefail, so without
  # `|| true`, a large enough history would abort the whole report right
  # here -- truncating it silently, with no error, before the slowest-tools
  # table the reader came for ever prints. The printed output is unaffected
  # either way. Same defect, same fix, as ct_tool_digest in lib/config.sh and
  # the on-screen aggregation in session-end.sh.
  if [ -n "$rows" ]; then
    echo
    echo "  slowest tools"
    local t_secs t_name t_calls
    while IFS=$'\x1f' read -r t_secs t_name t_calls; do
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
# text, no tool arguments, no paths. PROJECTS additionally names the project
# directory in each row -- never the path above it.
HISTORY=$CT_HISTORY
HISTORY_LIMIT=$CT_HISTORY_LIMIT
PROJECTS=$CT_PROJECTS

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
        # A here-string, not a pipe: `grep -q` exits as soon as it finds a
        # match, and on a config bigger than the pipe buffer that closes the
        # read end while printf is still writing, giving printf SIGPIPE.
        # Under this script's own pipefail, that reports the PIPELINE as
        # failed even though grep found exactly what it was looking for, so
        # `if` took the "not present" branch and dropped a real key. A
        # here-string feeds grep from a temp file bash itself writes, so the
        # match result no longer depends on how much of it grep chose to read.
        if grep -q "^${key}=" <<< "$existing"; then
          value="$(sed -n "s/^${key}=//p" <<< "$existing" | tail -1)"
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
  echo "  Projects        $CT_PROJECTS"
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
        # `|| true` at the very end of this pipeline: a broad enough search
        # term can match enough files that `head -25` closes the pipe once it
        # has its 25 lines, and `sort` -- which may still have more to write
        # -- gets SIGPIPE for it, even though every line `head` needed had
        # already been delivered. That makes the pipeline's exit status
        # nonzero for reasons that have nothing to do with the output being
        # wrong. This script runs under its own errexit/pipefail (see the top
        # of the file), so without `|| true`, a search that matched enough
        # zones would abort the wizard right here, mid-question. A reviewer
        # could not reproduce this on this machine's own zoneinfo size, but
        # the hazard is structural rather than size-dependent. Same defect,
        # same fix, as ct_tool_digest in lib/config.sh, the aggregation in
        # session-end.sh, and the slowest-tools pass in stats() below.
        find "$ZONEINFO" -type f -path "*$term*" 2>/dev/null \
          | sed "s|^$ZONEINFO/||" | grep -v '^posix/\|^right/\|\.' | sort | head -25 \
          || true
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
  # Unconditional: tool timing used to only change what the summary above
  # printed, which is why this was nested under it. It now also fills field 8
  # of the session history and feeds the --stats slowest-tools table, neither
  # of which depends on the summary being on, so nesting it here would cut
  # someone who answered "off" above away from the whole tool-breakdown
  # feature through the guided path.
  echo "Tool timing names the slowest tools in that summary and in --stats,"
  echo "and records what each tool call cost into the session history. It is"
  echo "the only setting that costs anything per tool call rather than per"
  echo "message."
  ask "Record what each tool call cost? (on/off)" "$CT_TOOL_TIMING"; answer="$_CT_ANSWER"
  case "$answer" in on|off) CT_TOOL_TIMING="$answer" ;; esac
  echo

  # The one part of the wizard that is not about what appears on screen. It
  # defaults to on, so a user who never reads the README has a file
  # accumulating in their home directory that nothing in the guided setup
  # mentions. Saying where it goes matters more than the question itself.
  echo "Finished sessions can be recorded, so the totals survive the session"
  echo "and --stats can add them up. Timings only, in"
  echo "  $(ct_tilde "$(ct_history_path)")"
  ask "Record finished sessions? (on/off)" "$CT_HISTORY"; answer="$_CT_ANSWER"
  case "$answer" in on|off) CT_HISTORY="$answer" ;; esac
  # Nested, because PROJECTS only ever changes what a recorded row contains.
  # Asked with HISTORY off, it would be a question whose answer does nothing.
  if [ "$CT_HISTORY" = "on" ]; then
    echo "  The record can name the project each session belonged to, which lets"
    echo "  --stats break the totals down per project. The directory's name only,"
    echo "  never the path above it."
    ask "  Name the project in each record? (on/off)" "$CT_PROJECTS"; answer="$_CT_ANSWER"
    case "$answer" in on|off) CT_PROJECTS="$answer" ;; esac
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
  local arg flag value i days
  # Parallel arrays with a counter of their own. bash 3.2 is what macOS ships:
  # it has no associative arrays, and under `set -u` it treats an empty array
  # as unset, so neither ${#arr[@]} nor a bare "${arr[@]}" is safe to lean on
  # there. A plain integer and the ${arr[@]+...} guard are.
  #
  # A key present in named_keys was named on this run, which is the whole of
  # what "named" used to need four separate *_named locals to express.
  local named_keys=() named_values=() named_count=0
  # Set when a stats-only flag was named, so the write-vs-report conflict
  # below can be detected without re-deriving it from `action` -- which
  # --since=* and --project=* both also set unconditionally, and set the
  # same way whether or not a setting flag came with them.
  local saw_stats_bare=0 saw_since_flag=0 since_flag_value=""
  local saw_project_filter=0

  while [ $# -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --config=*)  CLAUDE_TIMESTAMP_CONFIG="${arg#*=}"; export CLAUDE_TIMESTAMP_CONFIG ;;
      --project)   project_scope=1; interactive=0 ;;
      --show)      action="show";   interactive=0 ;;
      --doctor)    action="doctor"; interactive=0 ;;
      --stats)     action="stats";  interactive=0; saw_stats_bare=1 ;;
      --since=*)
        action="stats"; interactive=0
        value="${arg#*=}"
        saw_since_flag=1; since_flag_value="$value"
        case "$value" in
          *d)
            # [0-9]*d as a glob is "one digit, then anything, then a literal
            # d" -- the middle * matches any character, not just digits --
            # so "7dd" and "7x1d" both matched it too. ${value%d} then
            # stripped only the trailing d and handed ct_date_days_ago a
            # string it could not parse, which failed there and blamed the
            # platform ("This system's date cannot compute a cutoff")
            # instead of naming the flag the way the *) branch below does.
            # Validated here instead, against digits alone.
            days="${value%d}"
            case "$days" in
              ''|*[!0-9]*)
                echo "--since takes a number of days such as 7d, or a date such as 2026-09-01." >&2
                exit 2 ;;
            esac
            # Bounded to 6 digits. The plugin has not existed for anywhere
            # near the 2700-odd years that many days is, and it keeps
            # `days * 86400` in ct_date_days_ago far inside the shell's
            # 64-bit range, rather than accepted here and left to overflow,
            # or worse silently wrap, deep inside that arithmetic.
            if [ "${#days}" -gt 6 ]; then
              echo "--since takes a number of days such as 7d, or a date such as 2026-09-01." >&2
              exit 2
            fi
            # Stored, not resolved: CT_TZ is not loaded yet at parse time.
            # stats() resolves this into CT_STATS_SINCE right after it calls
            # ct_load_config.
            CT_STATS_SINCE_DAYS="$days" ;;
          [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9])
            CT_STATS_SINCE="$value" ;;
          *)
            echo "--since takes a number of days such as 7d, or a date such as 2026-09-01." >&2
            exit 2 ;;
        esac ;;
      --project=*)
        action="stats"; interactive=0
        saw_project_filter=1
        value="${arg#*=}"
        if [ -z "$value" ]; then
          echo "--project takes a name to filter by, such as my-app; it cannot be empty." >&2
          exit 2
        fi
        CT_STATS_PROJECT="$value" ;;
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

  # Three flags share a name and nothing else: bare --project selects
  # project scope for a setting being WRITTEN; --project=NAME is a --stats
  # filter; --projects=on|off is the setting that turns recording project
  # names on or off. Left unchecked, --project=NAME combined with a setting
  # to write silently picked the --stats action over the write, discarding
  # the write with no error -- and no project is plausibly named "on" or
  # "off", so that value is almost always a typo for --projects=.
  if [ "$saw_project_filter" = "1" ]; then
    case "$CT_STATS_PROJECT" in
      on|off)
        echo "--project=$CT_STATS_PROJECT looks like a typo for --projects=$CT_STATS_PROJECT." >&2
        echo "--project=NAME filters --stats by name; --projects=on|off is the setting" >&2
        echo "that turns recording project names on or off. No project is named '$CT_STATS_PROJECT'." >&2
        exit 2
        ;;
    esac
  fi

  # --stats and --since=* have the same write-vs-report conflict as
  # --project=NAME above: each sets action="stats" unconditionally, so a
  # setting flag named on the same run used to be silently discarded rather
  # than refused. Checked here, after the flags are all parsed, against
  # anything that writes a setting -- a --key=value flag (named_count), or
  # bare --project selecting write scope.
  if [ "$project_scope" = "1" ] || [ "$named_count" -gt 0 ]; then
    if [ "$saw_stats_bare" = "1" ]; then
      echo "--stats reports on recorded sessions; it does not write a setting." >&2
      echo "Drop --stats to write settings, or drop the setting flags to see the report." >&2
      exit 2
    fi
    if [ "$saw_since_flag" = "1" ]; then
      echo "--since=$since_flag_value filters --stats; it does not write a setting." >&2
      echo "Drop --since to write settings, or drop the setting flags to see the report." >&2
      exit 2
    fi
    if [ "$saw_project_filter" = "1" ]; then
      echo "--project=$CT_STATS_PROJECT filters --stats; it does not write a setting." >&2
      echo "Use bare --project to write a setting for the current project, or" >&2
      echo "--projects=on|off to change whether project names are recorded." >&2
      exit 2
    fi
  fi

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
