#!/usr/bin/env bash
# Test suite for claude-timestamp. Plain bash, no framework, no dependencies
# beyond what the plugin itself already needs.
#
#   bash tests/run.sh
#
# Every test runs against a temp config file via CLAUDE_TIMESTAMP_CONFIG and a
# temp TMPDIR, so a run never touches the real configuration or state.
# Three shellcheck codes are answered here once rather than at each of the
# sites, because they say something true of a test suite generally and would
# otherwise need repeating on every case added from here on.
#
# SC2012 (prefer find over ls): every name this suite reads back is one it
# wrote itself, and find -printf, the usual replacement, is GNU-only while CI
# runs the suite on BSD and Git Bash too.
#
# SC2030/SC2031 (a variable modified in a subshell): setting HOME, TMPDIR or
# LC_ALL inside a $( ) is how a hook is run under an environment of the
# suite's choosing without disturbing the rest of the run. That scoping is the
# isolation being asked for, not the accident it is reported as.
# shellcheck disable=SC2012,SC2030,SC2031
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ROOT
SCRIPTS="$ROOT/hooks/scripts"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n         expected: %s\n         actual:   %s\n' "$1" "$2" "$3"; }

is() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then pass "$label"; else fail "$label" "$expected" "$actual"; fi
}

# Assert a command fails. Written as a real branch rather than
# `cmd && fail || pass`, which also runs the third branch when the second one
# returns non-zero.
# Assert a command succeeds.
asserts() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "$label"; else fail "$label" "exit 0" "non-zero exit"; fi
}

refutes() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then fail "$label" "non-zero exit" "exit 0"; else pass "$label"; fi
}

# Record an assertion that this environment cannot run, without changing the
# total. The suite's assertion count is published in the README and checked by
# tools/check-docs.sh, so a case that runs only under some privilege would
# otherwise make that number unsatisfiable: right for whoever ran it locally
# and wrong for CI, or the reverse. Counted, and printed loudly enough that a
# skip is never mistaken for a pass.
skip() { PASS=$((PASS + 1)); printf '  SKIP %s\n         reason:   %s\n' "$1" "$2"; }

# Compare against a wall-clock value that can tick between two reads. The
# reference is sampled either side of the call and either is accepted: a minute
# boundary crossing mid-assertion is the clock moving, not the code being
# wrong. Three of these used to race, and a single one failing showed up in CI
# as "the suite reports 608" rather than as a failure, because tools/check-docs.sh
# reads only the passed count.
is_clock() {
  local label="$1" ref1="$2" actual="$3" ref2="$4"
  if [ "$actual" = "$ref1" ] || [ "$actual" = "$ref2" ]; then
    pass "$label"
  else
    fail "$label" "$ref1 or $ref2" "$actual"
  fi
}

# Assert a number is within a tolerance of the expected one. Used for values
# derived from the wall clock, where a test that pins an exact second races
# the code it is testing on a slow runner. The tolerance is chosen to still
# fail the bug being guarded against, not merely to stop the test complaining.
is_near() {
  local label="$1" expected="$2" actual="$3" tolerance="${4:-2}" diff
  case "$actual" in ''|*[!0-9-]*) fail "$label" "$expected (+/-$tolerance)" "$actual"; return ;; esac
  diff=$((actual - expected))
  [ "$diff" -lt 0 ] && diff=$(( -diff ))
  if [ "$diff" -le "$tolerance" ]; then
    pass "$label"
  else
    fail "$label" "$expected (+/-$tolerance)" "$actual"
  fi
}

# Assert a substring is absent. Used where recomputing a timestamp to compare
# against would race with the clock.
lacks() {
  local label="$1" needle="$2" haystack="$3"
  case "$haystack" in
    *"$needle"*) fail "$label" "no '$needle'" "$haystack" ;;
    *) pass "$label" ;;
  esac
}

# Remove colour escapes so an assertion can be about the text rather than the
# styling. The ESC byte is embedded literally because BSD sed does not
# understand \x1b the way GNU sed does.
strip_ansi() {
  printf '%s' "$1" | sed "s/$(printf '\033')\[[0-9;]*m//g"
}

# Reset configuration and session state, then load the config the case wants.
#
# Every scenario starts from a known-empty slate rather than whatever the last
# one left behind. Two bugs came from exactly that: a case inherited a stale
# rollover date, and later a stale idle timestamp, and failed for reasons that
# had nothing to do with what it asserted.
fresh() {
  rm -rf "$(ct_state_dir)"
  ct_state_ready
  rm -f "$CLAUDE_TIMESTAMP_HISTORY"
  if [ "$#" -gt 0 ]; then
    printf '%s\n' "$@" > "$CLAUDE_TIMESTAMP_CONFIG"
  else
    : > "$CLAUDE_TIMESTAMP_CONFIG"
  fi
  ct_load_config
}

contains() {
  local label="$1" needle="$2" haystack="$3"
  case "$haystack" in
    *"$needle"*) pass "$label" ;;
    *) fail "$label" "something containing '$needle'" "$haystack" ;;
  esac
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export TMPDIR="$WORK/state"

# Windows filesystems have neither POSIX mode bits nor, without developer mode
# enabled, real symlinks: `mkdir -m 700` yields drwxr-xr-x and `ln -s` copies.
# Probe once rather than testing $OSTYPE, because what matters is what this
# filesystem actually does, and skip the cases that need either. The skips are
# counted, so the assertion total is the same on every platform and the number
# the README publishes stays checkable.
mkdir -p "$WORK/cap"
CT_HAS_MODES=0
mkdir -m 700 "$WORK/cap/modes" 2>/dev/null
case "$(ls -ld "$WORK/cap/modes" 2>/dev/null)" in drwx------*) CT_HAS_MODES=1 ;; esac
CT_HAS_SYMLINKS=0
ln -s "$WORK/cap/modes" "$WORK/cap/link" 2>/dev/null
[ -L "$WORK/cap/link" ] && CT_HAS_SYMLINKS=1
mkdir -p "$TMPDIR"
export CLAUDE_TIMESTAMP_CONFIG="$WORK/config.conf"
export CLAUDE_TIMESTAMP_HISTORY="$WORK/history.tsv"
export CLAUDE_TIMESTAMP_FACTS="$WORK/facts.json"
export CLAUDE_TIMESTAMP_DRAWN="$WORK/drawn"

source "$SCRIPTS/lib/config.sh"
source "$SCRIPTS/lib/state.sh"

echo
echo "config parsing"

fresh
ct_load_config
is "defaults: display format" "24h" "$CT_DISPLAY_FORMAT"
# shellcheck disable=SC2153  # CT_COLOR is the library's variable, not a typo for NO_COLOR
is "defaults: color" "dim" "$CT_COLOR"
is "defaults: timezone is machine local" "" "$CT_TZ"
is "defaults: elapsed on" "on" "$CT_ELAPSED"

cat > "$CLAUDE_TIMESTAMP_CONFIG" <<'CONF'
# a comment
TZ=Asia/Tokyo

  DISPLAY_FORMAT = short
COLOR="cyan"
ELAPSED='off'
UNKNOWN_KEY=whatever
malformed line with no equals
CONF
ct_load_config
is "reads a value" "Asia/Tokyo" "$CT_TZ"
is "trims whitespace around key and value" "short" "$CT_DISPLAY_FORMAT"
is "strips double quotes" "cyan" "$CT_COLOR"
is "strips single quotes" "off" "$CT_ELAPSED"
is "unset key keeps its default" "24h" "$CT_CONTEXT_FORMAT"

# Written literally: this case is about the bytes in the file, so it cannot go
# through a helper that decides its own line endings.
printf 'TZ=Europe/Paris\r\nCOLOR=blue\r\n' > "$CLAUDE_TIMESTAMP_CONFIG"
ct_load_config
is "tolerates CRLF line endings" "Europe/Paris" "$CT_TZ"

printf 'COLOR=green' > "$CLAUDE_TIMESTAMP_CONFIG"   # deliberately no trailing newline
ct_load_config
is "reads a final line with no trailing newline" "green" "$CT_COLOR"

# The config file is parsed, never sourced. If it were sourced, this would
# create the file named in the substitution.
# shellcheck disable=SC2016  # the literal $(..) is exactly what is being tested
printf 'COLOR=$(touch %s/pwned)\n' "$WORK" > "$CLAUDE_TIMESTAMP_CONFIG"
ct_load_config
if [ -e "$WORK/pwned" ]; then fail "config file cannot execute code" "no file created" "command ran"; else pass "config file cannot execute code"; fi

# shellcheck disable=SC2088  # literal tilde is the expected output
is "a path under home is shortened" "~/.claude/x.conf" "$(HOME=/home/someone ct_tilde /home/someone/.claude/x.conf)"
is "a path outside home is left alone" "/etc/x.conf" "$(HOME=/home/someone ct_tilde /etc/x.conf)"
is "a path merely prefixed by home is left alone" "/home/someone-else/x" "$(HOME=/home/someone ct_tilde /home/someone-else/x)"

fresh 'MARKER=%time' 'TIME_COLOR=cyan' 'ELAPSED_COLOR=green' 'TOOL_COLOR=gray'
is "config: marker template"  "%time" "$CT_MARKER_TEMPLATE"
is "config: time colour"      "cyan"  "$CT_TIME_COLOR"
is "config: elapsed colour"   "green" "$CT_ELAPSED_COLOR"
is "config: tool colour"      "gray"  "$CT_TOOL_COLOR"

fresh
is "config: marker defaults to the current layout" \
  '[{%date }%time{ %elapsed}{ · %tool}]' "$CT_MARKER_TEMPLATE"
is "config: part colours default to inherit" "" "$CT_TIME_COLOR$CT_ELAPSED_COLOR$CT_TOOL_COLOR"

# The renderer writes CT_MARKER. If the config key loaded into the same
# variable, the first render would destroy the template.
fresh 'MARKER=%time'
ct_render_marker "$CT_MARKER_TEMPLATE" 13:22:13 '' '' ''
is "config: rendering does not clobber the template" "%time" "$CT_MARKER_TEMPLATE"

# --- the parser itself ------------------------------------------------------
#
# _ct_read_config_file is called directly here rather than through
# ct_load_config, because ct_load_config runs the validator afterwards and an
# unusable value is replaced by its default before an assertion could see what
# the parser actually stored. The cases that are about what a user ends up
# with call ct_validate_config explicitly, so both halves stay visible.
PARSE="$WORK/parse.conf"

# Every CT_* variable and its value, one line each, so a parse can be compared
# against the state it started from. LC_ALL=C so the ordering does not depend
# on the locale the suite happens to run under.
parse_dump() {
  local n
  for n in ${!CT_@}; do printf '%s=%s\n' "$n" "${!n}"; done | LC_ALL=C sort
}

# The names of the variables that a parse created or gave a new value. Lines
# present in the second dump and not the first are exactly those, which is why
# the comparison is on name=value pairs rather than on names alone: a name-set
# comparison cannot see a variable that already existed being written to.
parse_changed() {
  local out
  out="$(LC_ALL=C comm -13 <(printf '%s\n' "$1") <(printf '%s\n' "$2") \
         | sed 's/=.*//' | tr '\n' ' ')"
  printf '%s' "${out% }"
}

# Every key the whitelist names, in one file. A key that quietly stops being
# read fails here rather than in whichever feature happens to use it.
fresh
cat > "$PARSE" <<'CONF'
ENABLED=off
TZ=Asia/Tokyo
DISPLAY_FORMAT=short
CONTEXT_FORMAT=iso
COLOR=cyan
MARKER=%time
TIME_COLOR=green
ELAPSED_COLOR=blue
TOOL_COLOR=magenta
ELAPSED=off
DATE_ROLLOVER=off
SLOW_AFTER=5
SLOW_COLOR=red
IDLE_AFTER=7
SUMMARY=off
SUBAGENTS=off
TOOL_TIMING=on
HISTORY=off
HISTORY_LIMIT=9
INJECT_CONTEXT=false
CONF
parse_before="$(parse_dump)"
_ct_read_config_file "$PARSE"
parse_after="$(parse_dump)"
is "parse: ENABLED"        "off"        "$CT_ENABLED"
is "parse: TZ"             "Asia/Tokyo" "$CT_TZ"
is "parse: DISPLAY_FORMAT" "short"      "$CT_DISPLAY_FORMAT"
is "parse: CONTEXT_FORMAT" "iso"        "$CT_CONTEXT_FORMAT"
is "parse: COLOR"          "cyan"       "$CT_COLOR"
# The one key whose variable is not its own name, because the renderer already
# owns CT_MARKER for the rendered result.
is "parse: MARKER lands in the template variable" "%time" "$CT_MARKER_TEMPLATE"
is "parse: TIME_COLOR"     "green"      "$CT_TIME_COLOR"
is "parse: ELAPSED_COLOR"  "blue"       "$CT_ELAPSED_COLOR"
is "parse: TOOL_COLOR"     "magenta"    "$CT_TOOL_COLOR"
is "parse: ELAPSED"        "off"        "$CT_ELAPSED"
is "parse: DATE_ROLLOVER"  "off"        "$CT_DATE_ROLLOVER"
is "parse: SLOW_AFTER"     "5"          "$CT_SLOW_AFTER"
is "parse: SLOW_COLOR"     "red"        "$CT_SLOW_COLOR"
is "parse: IDLE_AFTER"     "7"          "$CT_IDLE_AFTER"
is "parse: SUMMARY"        "off"        "$CT_SUMMARY"
is "parse: SUBAGENTS"      "off"        "$CT_SUBAGENTS"
is "parse: TOOL_TIMING"    "on"         "$CT_TOOL_TIMING"
is "parse: HISTORY"        "off"        "$CT_HISTORY"
is "parse: HISTORY_LIMIT"  "9"          "$CT_HISTORY_LIMIT"
is "parse: INJECT_CONTEXT" "false"      "$CT_INJECT_CONTEXT"
# Twenty keys in, exactly those twenty variables touched and nothing else. The
# twenty assertions above say each key reached the right variable; this one
# says no other CT_* variable moved on the way -- a reader that also wrote the
# key's own name, or that let MARKER land in CT_MARKER as well as in the
# template, shows up here as an extra name in the list.
is "parse: exactly the twenty whitelisted variables are written" \
  "CT_COLOR CT_CONTEXT_FORMAT CT_DATE_ROLLOVER CT_DISPLAY_FORMAT CT_ELAPSED CT_ELAPSED_COLOR CT_ENABLED CT_HISTORY CT_HISTORY_LIMIT CT_IDLE_AFTER CT_INJECT_CONTEXT CT_MARKER_TEMPLATE CT_SLOW_AFTER CT_SLOW_COLOR CT_SUBAGENTS CT_SUMMARY CT_TIME_COLOR CT_TOOL_COLOR CT_TOOL_TIMING CT_TZ" \
  "$(parse_changed "$parse_before" "$parse_after")"

# A value may itself contain '=', so the split is on the first one only.
fresh
printf 'TOOL_TIMING=on=off\n' > "$PARSE"
_ct_read_config_file "$PARSE"
is "parse: the value splits on the first = only" "on=off" "$CT_TOOL_TIMING"

fresh
printf 'COLOR = cyan\nDISPLAY_FORMAT =    \n' > "$PARSE"
_ct_read_config_file "$PARSE"
is "parse: spaces either side of = are trimmed" "cyan" "$CT_COLOR"
is "parse: a value of only spaces trims to empty" "" "$CT_DISPLAY_FORMAT"

# Quote stripping needs a matched pair. A lone opening quote is part of the
# value, which is what makes it reach the validator as the nonsense it is
# rather than being silently repaired into something plausible.
fresh
printf 'COLOR="cyan\nTZ=%s\n' "'UTC" > "$PARSE"
_ct_read_config_file "$PARSE"
is "parse: an unmatched double quote stays in the value" '"cyan' "$CT_COLOR"
is "parse: an unmatched single quote stays in the value" "'UTC" "$CT_TZ"
ct_validate_config
is "parse: the unmatched quote makes the colour invalid" "dim" "$CT_COLOR"
contains "parse: and the problem names the value as written" \
  'COLOR="cyan is not valid' "$CT_CONFIG_PROBLEMS"

# A matched pair around nothing is how a config file says "empty", which two
# settings read as opposite answers: no colour name at all is a typo, no part
# colour means inherit the base one.
fresh
printf 'COLOR=""\nTIME_COLOR=%s\n' "''" > "$PARSE"
_ct_read_config_file "$PARSE"
is "parse: an empty double-quoted value strips to empty" "" "$CT_COLOR"
is "parse: an empty single-quoted value strips to empty" "" "$CT_TIME_COLOR"
ct_validate_config
is "parse: an empty COLOR is invalid and falls back" "dim" "$CT_COLOR"
is "parse: an empty TIME_COLOR means inherit, not invalid" "" "$CT_TIME_COLOR"

# Written literally: this case is about the bytes in the file. One CR-ended
# line with no newline after it is both awkward shapes at once.
#
# What this pins is the outcome the contract states -- a CRLF config reads the
# same as a LF one -- rather than the `%$'\r'` line specifically. Measured with
# that line removed, this and the CRLF case above both still pass, because CR
# is in [[:space:]] and the trailing-whitespace trim takes it off the value
# anyway. The explicit strip is belt and braces for a shape the trim happens to
# cover; there is no input that reaches only it, so there is nothing further to
# assert here.
fresh
printf 'COLOR=cyan\r' > "$PARSE"
_ct_read_config_file "$PARSE"
is "parse: a CR-ended final line with no newline is still read" "cyan" "$CT_COLOR"

# The =-less guard is the load-bearing half of this one: without it the line
# "COLOR" parses as key and value both "COLOR" and the setting changes.
#
# The leading-'#' guard, measured, is not observable from out here at all. A
# comment that mentions a setting still carries its '#' into the key -- '#' is
# not whitespace, so no trim removes it -- and "# COLOR" is not on the
# whitelist. Removing the guard entirely changes nothing this function can be
# asked about. It stays as a cheap early exit, and this case asserts the
# outcome the contract names rather than pretending to pin it.
fresh
printf '\n   \n# COLOR=banana\nmalformed line with no equals\nCOLOR\n' > "$PARSE"
_ct_read_config_file "$PARSE"
is "parse: blank, whitespace, comment and =-less lines are skipped" "dim" "$CT_COLOR"

# The comment guard is anchored at the first character, so an indented '#' is
# not a comment. The line has an '=' in it and is parsed as the key '# COLOR',
# which is not on the whitelist, so the setting it mentions is still left
# alone. Same outcome, different reason, and worth pinning: a reader that
# matched the key loosely -- on a substring, or after stripping the punctuation
# out of it -- would set COLOR to banana off a line that is only talking about
# it. (A reader that trimmed before testing for '#' would skip the line as a
# comment and land on the same answer, so that variant is not what this
# detects; the loose match is.)
fresh
printf '   # COLOR=banana\n' > "$PARSE"
_ct_read_config_file "$PARSE"
is "parse: an indented comment does not set the key it names" "dim" "$CT_COLOR"

# An empty key matches no arm of the case statement, so nothing is assigned
# and nothing new appears.
fresh
parse_before="$(parse_dump)"
printf '=orphan\n' > "$PARSE"
_ct_read_config_file "$PARSE"
is "parse: a line with an empty key changes nothing" \
  "dim 24h on" "$CT_COLOR $CT_DISPLAY_FORMAT $CT_ELAPSED"
is "parse: a line with an empty key touches no variable at all" \
  "" "$(parse_changed "$parse_before" "$(parse_dump)")"

# Unknown keys are ignored rather than being an error, so a file written by a
# newer version stays readable by an older one. What matters is that the keys
# around them still land: a reader that gave up on the first unknown key would
# read the file down to THEME and no further.
fresh
parse_before="$(parse_dump)"
printf 'COLOR=cyan\nUNKNOWN_KEY=whatever\nTHEME=x\nELAPSED=off\n' > "$PARSE"
_ct_read_config_file "$PARSE"
is "parse: an unknown key leaves the key before it alone" "cyan" "$CT_COLOR"
is "parse: an unknown key leaves the key after it alone"  "off"  "$CT_ELAPSED"
# Ignored means ignored, not stored under a name nobody reads. A reader that
# assigned by name would leave CT_UNKNOWN_KEY and CT_THEME behind here.
is "parse: an unknown key is not stored under a variable of its own" \
  "CT_COLOR CT_ELAPSED" "$(parse_changed "$parse_before" "$(parse_dump)")"

# Parsed, never sourced. The ct_load_config case above proves no file gets
# created; these prove what was stored instead, which is the other half of the
# same claim -- a reader that ran the command and stored its empty output
# would pass a check that only looked for the file.
fresh
rm -rf "$WORK/victim" "$WORK/pwned-tick"
mkdir -p "$WORK/victim"
# shellcheck disable=SC2016  # the literal backticks are exactly what is tested
printf 'MARKER=`touch %s/pwned-tick`\nTZ=UTC;rm -rf %s/victim\n' "$WORK" "$WORK" > "$PARSE"
_ct_read_config_file "$PARSE"
is "parse: a backticked value is stored as literal text" \
  '`touch '"$WORK"'/pwned-tick`' "$CT_MARKER_TEMPLATE"
is "parse: a value carrying a shell separator is stored whole" \
  "UTC;rm -rf $WORK/victim" "$CT_TZ"
if [ -e "$WORK/pwned-tick" ]; then
  fail "parse: no command in the file is run" "no file created" "the backticks ran"
else
  pass "parse: no command in the file is run"
fi
asserts "parse: a value naming a directory does not delete it" test -d "$WORK/victim"
rm -rf "$WORK/victim"

# ct_load_config calls this twice, the user file and then the project file,
# and the project layer is only worth having if the second call overrides the
# keys it names and nothing else.
fresh
printf 'COLOR=cyan\nTZ=Asia/Tokyo\nELAPSED=off\n' > "$PARSE"
printf 'COLOR=green\n' > "$WORK/parse-over.conf"
_ct_read_config_file "$PARSE"
_ct_read_config_file "$WORK/parse-over.conf"
is "parse: a second file overrides the key it sets" "green" "$CT_COLOR"
is "parse: a second file leaves a key it does not set" "Asia/Tokyo" "$CT_TZ"
is "parse: including one already moved off its default" "off" "$CT_ELAPSED"

echo
echo "format presets"

is "24h preset"   '%H:%M:%S'           "$(ct_expand_format 24h)"
is "short preset" '%H:%M'              "$(ct_expand_format short)"
is "12h preset"   '%I:%M %p'           "$(ct_expand_format 12h)"
is "iso preset"   '%Y-%m-%dT%H:%M:%S'  "$(ct_expand_format iso)"
is "raw strftime passes through" '%A %H:%M' "$(ct_expand_format '%A %H:%M')"
is "unknown preset falls back to 24h" '%H:%M:%S' "$(ct_expand_format nonsense)"

fresh
ct_load_config
# Needs a timezone database. Git Bash on Windows has none, and the fallback
# behaviour for that case is asserted separately below.
if ct_tz_supported; then
  CT_TZ="Asia/Tokyo"
  CT_DISPLAY_FORMAT="iso"
  tokyo="$(ct_now iso)"
  CT_TZ="UTC"
  utc="$(ct_now iso)"
  if [ "$tokyo" != "$utc" ]; then
    pass "timezone actually changes the rendered time"
  else
    fail "timezone actually changes the rendered time" "different times" "both $utc"
  fi
else
  echo "  skip timezone actually changes the rendered time (no timezone database)"
fi

CT_TZ="UTC"
case "$(ct_now 12h)" in 0*) fail "12h preset trims the leading zero" "no leading zero" "$(ct_now 12h)" ;; *) pass "12h preset trims the leading zero" ;; esac

echo
echo "timezone capability"

fresh
ct_load_config
CT_TZ="Asia/Tokyo"

# CT_TZ_SUPPORTED is read by the sourced library, which shellcheck cannot see.
# shellcheck disable=SC2034
# Simulate a platform without a timezone database (Git Bash on Windows) by
# priming the memoised probe, and assert the pinned zone is ignored rather
# than rendered as UTC.
CT_TZ_SUPPORTED="no"
cl_ref1="$(date '+%H:%M')"; cl_got="$(ct_now short)"; cl_ref2="$(date '+%H:%M')"
is_clock "an unhonourable zone falls back to local time" "$cl_ref1" "$cl_got" "$cl_ref2"
if ct_tz_unhonoured; then pass "a pinned but unsupported zone is reported"; else fail "a pinned but unsupported zone is reported" "true" "false"; fi

# shellcheck disable=SC2034  # read by the sourced library
CT_TZ_SUPPORTED="yes"
if ct_tz_supported; then
  cl_ref1="$(TZ=Asia/Tokyo date '+%H:%M')"; cl_got="$(ct_now short)"; cl_ref2="$(TZ=Asia/Tokyo date '+%H:%M')"
  is_clock "a supported zone is applied" "$cl_ref1" "$cl_got" "$cl_ref2"
else
  echo "  skip a supported zone is applied (no timezone database)"
fi
CT_TZ="UTC"
cl_ref1="$(TZ=UTC date '+%H:%M')"; cl_got="$(ct_now short)"; cl_ref2="$(TZ=UTC date '+%H:%M')"
is_clock "UTC is honoured with or without a timezone database" "$cl_ref1" "$cl_got" "$cl_ref2"

CT_TZ=""
if ct_tz_unhonoured; then fail "no pinned zone is never reported as unhonoured" "false" "true"; else pass "no pinned zone is never reported as unhonoured"; fi
unset CT_TZ_SUPPORTED

echo
echo "elapsed formatting"

is "seconds only"        "+45s"    "$(ct_format_elapsed 45)"
is "zero seconds"        "+0s"     "$(ct_format_elapsed 0)"
is "just under a minute" "+59s"    "$(ct_format_elapsed 59)"
is "exactly one minute"  "+1m00s"  "$(ct_format_elapsed 60)"
is "minutes and seconds" "+2m14s"  "$(ct_format_elapsed 134)"
is "pads seconds"        "+5m03s"  "$(ct_format_elapsed 303)"
is "exactly one hour"    "+1h00m"  "$(ct_format_elapsed 3600)"
is "hours and minutes"   "+1h03m"  "$(ct_format_elapsed 3780)"
is "a full day"          "+25h00m" "$(ct_format_elapsed 90000)"
is "many days"           "+100h00m" "$(ct_format_elapsed 360000)"
refutes "rejects non-numeric input" ct_format_elapsed "abc"
refutes "rejects negative input" ct_format_elapsed "-5"

is "duration: seconds"        "45s"    "$(ct_format_duration 45)"
is "duration: minutes"        "2m14s"  "$(ct_format_duration 134)"
is "duration: hours"          "1h03m"  "$(ct_format_duration 3780)"
refutes "duration rejects rubbish" ct_format_duration "x"

is "gap: minutes"             "35m"    "$(ct_humanize_gap 2100)"
is "gap: just under 90m"      "89m"    "$(ct_humanize_gap 5399)"
is "gap: hours"               "2h"     "$(ct_humanize_gap 7200)"
is "gap: days"                "3d"     "$(ct_humanize_gap 259200)"
refutes "gap rejects rubbish" ct_humanize_gap "x"

echo
echo "counters and state"

is "missing counter reads as zero" "0" "$(ct_read_counter "$WORK/nope")"
printf 'garbage' > "$WORK/counter"
is "corrupt counter reads as zero" "0" "$(ct_read_counter "$WORK/counter")"
printf '42' > "$WORK/counter"
is "valid counter is read" "42" "$(ct_read_counter "$WORK/counter")"

# State files are written with printf '%s' and carry no trailing newline, so
# `read` always reports failure even though it has already assigned the value.
# Under the hooks' own `set -euo pipefail` that would abort the script, and the
# only reason it does not is that bash clears errexit inside a command
# substitution. That default is not guaranteed: BASHOPTS carries
# inherit_errexit in from the environment, and a maintainer can set it with one
# `shopt`. Then every state read kills its hook at the first counter it touches
# and the plugin goes silent with nothing reported.
#
# On a bash too old to have inherit_errexit (3.2, which macOS ships) an unknown
# BASHOPTS entry is ignored at startup, so this degrades to an ordinary read
# rather than failing.
# shellcheck disable=SC2016  # $1 and $2 are for the inner bash, not this one
is "a counter is read under inherit_errexit" "42" \
  "$(env BASHOPTS=inherit_errexit bash -c '
       set -euo pipefail
       . "$1/lib/config.sh"; . "$1/lib/state.sh"
       ct_read_counter "$2"
     ' _ "$SCRIPTS" "$WORK/counter" 2>/dev/null)"

mkdir -p "$(ct_state_dir)"
base="$(ct_state_file "clearme")"
printf '1' > "$base"; printf '2' > "$base.turns"; printf '3' > "$base.wait"
ct_clear_state "clearme"
if [ -e "$base" ] || [ -e "$base.turns" ] || [ -e "$base.wait" ]; then
  fail "clearing a session removes all of its state" "no files" "some remain"
else
  pass "clearing a session removes all of its state"
fi

echo
echo "painting"

is "paint with no colour returns the text" "hi" "$(ct_paint none hi)"
contains "paint wraps in the colour" "[33m" "$(ct_paint yellow hi)"
contains "paint resets afterwards" "[0m" "$(ct_paint yellow hi)"

echo
echo "state files"

is "session id becomes a path under the state dir" "$(ct_state_dir)/abc-123" "$(ct_state_file "abc-123")"
is "traversal characters are stripped from the session id" "$(ct_state_dir)/etcpasswd" "$(ct_state_file "../../etc/passwd")"
refutes "empty session id is refused" ct_state_file ""
refutes "session id of only separators is refused" ct_state_file "///"

# The assigning form the hot paths use, so the two cannot drift apart: the
# printing one costs a subshell at every call site, and post-tool-use.sh
# reaches this four times per timed tool call.
ct_state_file_var "abc-123"
is "the assigning form agrees with the printing one" "$(ct_state_file "abc-123")" "$_CT_STATE_FILE"
refutes "the assigning form refuses an empty id" ct_state_file_var ""

# The staged flags the tool hook reads instead of resolving configuration
# itself. Round-tripped here so the helpers have cover of their own rather
# than only being exercised through a hook.
mkdir -p "$(ct_state_dir)"
ct_stage_flag "flagrt" "tooltiming" "on"
is "a staged flag reads back"        "on" "$(ct_read_flag "flagrt" "tooltiming")"
is "an unstaged flag reads as empty" ""   "$(ct_read_flag "flagrt" "nosuchflag")"
ct_clear_flag "flagrt" "tooltiming"
is "a cleared flag reads as empty"   ""   "$(ct_read_flag "flagrt" "tooltiming")"
ct_clear_state "flagrt"

# The state directory is shared ground on any machine without a per-user
# TMPDIR. A directory somebody else owns is refused rather than written into,
# and no filename in it is predictable enough to be pre-planted as a symlink.
# Computed before the assertion, not inside $( ): bash 3.2 closes a command
# substitution on the first unparenthesised `)` in a case pattern, so the whole
# suite failed to parse on macOS.
case "$(ct_state_dir)" in
  *"claude-timestamp-$(id -u)") per_user=1 ;;
  *) per_user=0 ;;
esac
is "state dir: is per-user" "1" "$per_user"

fresh
rm -rf "$(ct_state_dir)"
asserts "state dir: a fresh directory is accepted" ct_state_ready
# shellcheck disable=SC2012  # ls -ld is the portable way to read a mode
# string; find -printf is a GNU extension.
if [ "$CT_HAS_MODES" = "1" ]; then
  is "state dir: created private to us" "drwx------" \
     "$(ls -ld "$(ct_state_dir)" | cut -c1-10)"
else
  skip "state dir: created private to us" \
       "this filesystem does not carry POSIX mode bits"
fi

# Ownership alone was never the guarantee. A directory we own but that anyone
# can write to lets any local user create a symlink inside it, which is the
# original attack with one extra step.
fresh
chmod 777 "$(ct_state_dir)"
asserts "state dir: a permissive mode is repaired, not refused" ct_state_ready
# shellcheck disable=SC2012  # ls -ld is the portable way to read a mode
# string; find -printf is a GNU extension.
if [ "$CT_HAS_MODES" = "1" ]; then
  is "state dir: and it ends up private" "drwx------" \
     "$(ls -ld "$(ct_state_dir)" | cut -c1-10)"
else
  skip "state dir: and it ends up private" \
       "this filesystem does not carry POSIX mode bits"
fi

# A symlink at the state directory path is refused outright, whoever owns it.
#
# This is the whole reason ownership is settled with `[ -L ]` before `[ -O ]`:
# -d, -O and chmod all FOLLOW a symlink, and ls -ld does not. A build that
# checked ownership with a bare `[ -O ]` accepted an attacker-planted symlink
# and then chmod'd the attacker's chosen target -- measured, a victim directory
# went 755 -> 700. Refusing every symlink also covers the case the ownership
# comparison always let through: one we planted ourselves.
if [ "$CT_HAS_SYMLINKS" = "1" ] && [ "$CT_HAS_MODES" = "1" ]; then
  fresh
  victim="$(ct_state_dir).victim"
  rm -rf "$victim" "$(ct_state_dir)"
  mkdir -p "$victim"
  chmod 755 "$victim"
  ln -s "$victim" "$(ct_state_dir)"
  refutes "state dir: a symlink is refused even when we own it" ct_state_ready
  is "state dir: and the symlink's target is left alone" "755" \
     "$(stat -c%a "$victim" 2>/dev/null || stat -f%Lp "$victim")"
  rm -f "$(ct_state_dir)"
  rm -rf "$victim"
else
  skip "state dir: a symlink is refused even when we own it" \
       "needs real symlinks and POSIX mode bits"
  skip "state dir: and the symlink's target is left alone" \
       "needs real symlinks and POSIX mode bits"
fi

# The directory can vanish under a live session: /tmp is swept on many systems.
# Nothing about the verdict may be remembered, or the process keeps reporting a
# directory that is no longer there.
#
# These two pass against the code as it stands and are not regression
# detectors. They are here because the obvious way to make ct_state_ready
# cheaper is to cache its verdict, and that was tried: it takes 31 other cases
# down with it, for this reason. The pair states the constraint at the point
# where someone would otherwise have to rediscover it.
fresh
ct_state_ready || true
rm -rf "$(ct_state_dir)"
# Note the split: the exit status alone cannot detect remembering, because a
# cached verdict returns 0 too. The directory test on the next line is the one
# that catches it.
asserts "state dir: a vanished directory is still accepted" ct_state_ready
is "state dir: and it really is back on disk, not just remembered" "1" \
   "$([ -d "$(ct_state_dir)" ] && echo 1 || echo 0)"

# The window the [ -L ] guard cannot close: an entry swapped for a symlink
# after the guard ran but before the mode is read. `ls` is shimmed because
# winning that race for real is timing-dependent, and what needs proving is
# what the code does with the line it gets back, not that the race is winnable.
# Without the `d*)` arm this chmods the symlink's target and returns 0.
fresh
chmod 755 "$(ct_state_dir)"
# shellcheck disable=SC2317  # invoked indirectly, from inside ct_state_ready
ls() { printf 'lrwxrwxrwx 1 %s %s 12 Jan 1 00:00 x -> y\n' "$(id -un)" "$(id -gn)"; }
refutes "state dir: a swapped-in symlink is refused at the mode check" ct_state_ready
unset -f ls
# The refusal has to happen INSTEAD of the repair, not after it. Pre-fix, the
# catch-all arm chmod'd first and only then carried on, so the mode moved.
is "state dir: and the refusal ran instead of the chmod, not after it" "755" \
   "$(stat -c%a "$(ct_state_dir)" 2>/dev/null || stat -f%Lp "$(ct_state_dir)")"

# The legacy shared directory is untrusted ground now: another user may own it
# and may have put things in it. The sweep must reach only old regular files
# sitting directly inside it.
fresh
legacy="${TMPDIR:-/tmp}/claude-timestamp"
rm -rf "$legacy"; mkdir -p "$legacy/sub"
: > "$legacy/old"; : > "$legacy/sub/deep"
touch -t 200001010000 "$legacy/old" "$legacy/sub/deep"
ct_prune_state
refutes "prune: an old file in the legacy directory is swept" test -e "$legacy/old"
asserts "prune: a file one level deeper is left alone"        test -e "$legacy/sub/deep"
rm -rf "$legacy"

# And it must not follow the legacy path if that path is itself a symlink,
# which is the cheapest way for somebody else to aim the sweep at your files.
fresh
elsewhere="${TMPDIR:-/tmp}/ct-elsewhere"
rm -rf "$legacy" "$elsewhere"; mkdir -p "$elsewhere"
: > "$elsewhere/keep"; touch -t 200001010000 "$elsewhere/keep"
ln -s "$elsewhere" "$legacy"
ct_prune_state
asserts "prune: a symlinked legacy directory is not followed" test -e "$elsewhere/keep"
rm -rf "$legacy" "$elsewhere"

# Declining a directory somebody else owns needs a directory somebody else
# owns, which needs privileges the suite does not usually have. Run it when we
# can and say so when we cannot, rather than skipping in silence.
if [ "$(id -u)" = "0" ]; then
  fresh
  chown 65534:65534 "$(ct_state_dir)" 2>/dev/null
  refutes "state dir: one owned by another user is declined" ct_state_ready
  chown "$(id -u):$(id -g)" "$(ct_state_dir)" 2>/dev/null
else
  skip "state dir: one owned by another user is declined" \
       "needs a directory owned by somebody else, so it needs root"
fi

echo
echo "color"

contains "dim emits an ANSI sequence" "[2m" "$(ct_color_start dim)"
is "none emits nothing" "" "$(ct_color_start none)"
is "unknown color emits nothing" "" "$(ct_color_start banana)"
is "no reset when there was no color" "" "$(ct_color_end none)"
contains "reset follows a real color" "[0m" "$(ct_color_end dim)"
is "NO_COLOR disables color" "" "$(NO_COLOR=1 ct_color_start dim)"

ct_color_seq dim
is "color seq: dim"            "$(printf '\033[2m')" "$_CT_SEQ"
ct_color_seq cyan
is "color seq: cyan"           "$(printf '\033[36m')" "$_CT_SEQ"
ct_color_seq none
is "color seq: none is empty"  "" "$_CT_SEQ"
ct_color_seq banana
is "color seq: unknown is empty" "" "$_CT_SEQ"
ct_color_seq ""
is "color seq: empty is empty" "" "$_CT_SEQ"

# NO_COLOR wins over any named colour, the same way it does for ct_color_start.
if ( NO_COLOR=1; ct_color_seq cyan; [ -z "$_CT_SEQ" ] ); then
  pass "color seq: NO_COLOR silences it"
else
  fail "color seq: NO_COLOR silences it" "empty" "non-empty"
fi

# ct_color_start must keep behaving exactly as before, now that it shares a table.
is "color start still works"   "$(printf '\033[36m')" "$(ct_color_start cyan)"
is "color start: none is empty" "" "$(ct_color_start none)"

# Painting one part restores the base colour afterwards, so literal text that
# follows is not left wearing the part's colour.
ct_paint_part cyan "13:22" dim
is "paint part: wraps and restores" \
  "$(printf '\033[36m13:22\033[0m\033[2m')" "$_CT_PART"

ct_paint_part none "13:22" dim
is "paint part: no colour leaves text bare" "13:22" "$_CT_PART"

ct_paint_part cyan "" dim
is "paint part: an empty part stays empty" "" "$_CT_PART"

ct_paint_part cyan "x" ""
is "paint part: an empty base restores nothing" \
  "$(printf '\033[36mx\033[0m')" "$_CT_PART"

# Both helpers must always return 0: the real hook runs under set -e, where a
# stray non-zero return in an unmatched branch would abort the marker render.
asserts "color seq returns 0 for a known colour"   ct_color_seq cyan
asserts "color seq returns 0 for an unknown colour" ct_color_seq banana
asserts "color seq returns 0 for an empty colour"  ct_color_seq ""
asserts "paint part returns 0 with text"           ct_paint_part cyan "x" dim
asserts "paint part returns 0 with empty text"     ct_paint_part cyan "" dim
asserts "paint part returns 0 with an empty base"  ct_paint_part cyan "x" ""

if ( NO_COLOR=1; ct_color_seq cyan ); then
  pass "color seq returns 0 under NO_COLOR"
else
  fail "color seq returns 0 under NO_COLOR" "exit 0" "non-zero exit"
fi

# CLAUDE_CODE_ENTRYPOINT is set by Claude Code and inherited by every hook, as
# any child process would inherit it. A client that does not render ANSI (the
# VS Code extension is CLAUDE_CODE_ENTRYPOINT=claude-vscode) must get plain
# text, or the marker shows as literal "[2m...[0m" on screen. Only "cli" and
# unset earn colour; every other value, including ones invented after this was
# written, gets plain text. Each case below sets the variables in a subshell
# so they cannot leak into later tests and silently disable colour for the
# rest of the suite -- exactly the hazard NO_COLOR's tests already guard
# against above.

if ( unset CLAUDE_CODE_ENTRYPOINT
     ct_color_seq dim; [ -n "$_CT_SEQ" ] ); then
  pass "entrypoint unset: color seq gets colour"
else
  fail "entrypoint unset: color seq gets colour" "non-empty" "empty"
fi
if ( unset CLAUDE_CODE_ENTRYPOINT
     ct_paint_part dim "13:22" ""; [ "$_CT_PART" != "13:22" ] ); then
  pass "entrypoint unset: paint part gets colour"
else
  fail "entrypoint unset: paint part gets colour" "coloured" "plain"
fi

if ( CLAUDE_CODE_ENTRYPOINT=cli
     ct_color_seq dim; [ -n "$_CT_SEQ" ] ); then
  pass "entrypoint cli: color seq gets colour"
else
  fail "entrypoint cli: color seq gets colour" "non-empty" "empty"
fi
if ( CLAUDE_CODE_ENTRYPOINT=cli
     ct_paint_part dim "13:22" ""; [ "$_CT_PART" != "13:22" ] ); then
  pass "entrypoint cli: paint part gets colour"
else
  fail "entrypoint cli: paint part gets colour" "coloured" "plain"
fi

if ( CLAUDE_CODE_ENTRYPOINT=claude-vscode
     ct_color_seq dim; [ -z "$_CT_SEQ" ] ); then
  pass "entrypoint claude-vscode: color seq gets no colour"
else
  fail "entrypoint claude-vscode: color seq gets no colour" "empty" "non-empty"
fi
if ( CLAUDE_CODE_ENTRYPOINT=claude-vscode
     ct_paint_part dim "13:22" ""; [ "$_CT_PART" = "13:22" ] ); then
  pass "entrypoint claude-vscode: paint part gets no colour"
else
  fail "entrypoint claude-vscode: paint part gets no colour" "13:22" "coloured"
fi

if ( CLAUDE_CODE_ENTRYPOINT=sdk-cli
     ct_color_seq dim; [ -z "$_CT_SEQ" ] ); then
  pass "entrypoint sdk-cli: color seq gets no colour"
else
  fail "entrypoint sdk-cli: color seq gets no colour" "empty" "non-empty"
fi
if ( CLAUDE_CODE_ENTRYPOINT=sdk-cli
     ct_paint_part dim "13:22" ""; [ "$_CT_PART" = "13:22" ] ); then
  pass "entrypoint sdk-cli: paint part gets no colour"
else
  fail "entrypoint sdk-cli: paint part gets no colour" "13:22" "coloured"
fi

if ( CLAUDE_CODE_ENTRYPOINT=something-invented-later
     ct_color_seq dim; [ -z "$_CT_SEQ" ] ); then
  pass "unknown future entrypoint: color seq gets no colour"
else
  fail "unknown future entrypoint: color seq gets no colour" "empty" "non-empty"
fi
if ( CLAUDE_CODE_ENTRYPOINT=something-invented-later
     ct_paint_part dim "13:22" ""; [ "$_CT_PART" = "13:22" ] ); then
  pass "unknown future entrypoint: paint part gets no colour"
else
  fail "unknown future entrypoint: paint part gets no colour" "13:22" "coloured"
fi

# Set-but-empty is not the same signal as unset: something touched the
# variable and produced a non-cli result, so it must fall through to no
# colour rather than being read as "never set" and defaulting to cli. This is
# exactly what distinguishes the guard's single-dash expansion
# (${CLAUDE_CODE_ENTRYPOINT-cli}) from :-, which would collapse the two cases.
if ( CLAUDE_CODE_ENTRYPOINT=""
     ct_color_seq dim; [ -z "$_CT_SEQ" ] ); then
  pass "entrypoint set to empty string: color seq gets no colour"
else
  fail "entrypoint set to empty string: color seq gets no colour" "empty" "non-empty"
fi
if ( CLAUDE_CODE_ENTRYPOINT=""
     ct_paint_part dim "13:22" ""; [ "$_CT_PART" = "13:22" ] ); then
  pass "entrypoint set to empty string: paint part gets no colour"
else
  fail "entrypoint set to empty string: paint part gets no colour" "13:22" "coloured"
fi

if ( NO_COLOR=1 CLAUDE_CODE_ENTRYPOINT=cli
     ct_color_seq dim; [ -z "$_CT_SEQ" ] ); then
  pass "NO_COLOR beats a cli entrypoint: color seq gets no colour"
else
  fail "NO_COLOR beats a cli entrypoint: color seq gets no colour" "empty" "non-empty"
fi
if ( NO_COLOR=1 CLAUDE_CODE_ENTRYPOINT=cli
     ct_paint_part dim "13:22" ""; [ "$_CT_PART" = "13:22" ] ); then
  pass "NO_COLOR beats a cli entrypoint: paint part gets no colour"
else
  fail "NO_COLOR beats a cli entrypoint: paint part gets no colour" "13:22" "coloured"
fi

if ( FORCE_COLOR=1 CLAUDE_CODE_ENTRYPOINT=claude-vscode
     ct_color_seq dim; [ -n "$_CT_SEQ" ] ); then
  pass "FORCE_COLOR beats a non-cli entrypoint: color seq gets colour"
else
  fail "FORCE_COLOR beats a non-cli entrypoint: color seq gets colour" "non-empty" "empty"
fi
# shellcheck disable=SC2034  # read by ct_paint_part inside the subshell, not here
if ( FORCE_COLOR=1 CLAUDE_CODE_ENTRYPOINT=claude-vscode
     ct_paint_part dim "13:22" ""; [ "$_CT_PART" != "13:22" ] ); then
  pass "FORCE_COLOR beats a non-cli entrypoint: paint part gets colour"
else
  fail "FORCE_COLOR beats a non-cli entrypoint: paint part gets colour" "coloured" "plain"
fi

if ( NO_COLOR=1 FORCE_COLOR=1
     ct_color_seq dim; [ -z "$_CT_SEQ" ] ); then
  pass "NO_COLOR beats FORCE_COLOR: color seq gets no colour"
else
  fail "NO_COLOR beats FORCE_COLOR: color seq gets no colour" "empty" "non-empty"
fi
# shellcheck disable=SC2034  # read by ct_paint_part inside the subshell, not here
if ( NO_COLOR=1 FORCE_COLOR=1
     ct_paint_part dim "13:22" ""; [ "$_CT_PART" = "13:22" ] ); then
  pass "NO_COLOR beats FORCE_COLOR: paint part gets no colour"
else
  fail "NO_COLOR beats FORCE_COLOR: paint part gets no colour" "13:22" "coloured"
fi

echo
echo "hooks"

if command -v jq >/dev/null 2>&1; then
  fresh

  out="$(printf '{"session_id":"test-session","index":0,"delta":"Hello there."}' | bash "$SCRIPTS/message-display.sh")"
  contains "message-display stamps index 0" "displayContent" "$out"
  contains "message-display keeps the original text" "Hello there." "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.displayContent')"

  out="$(printf '{"session_id":"test-session","index":3,"delta":"more text"}' | bash "$SCRIPTS/message-display.sh")"
  is "message-display emits nothing for later batches" "" "$out"

  # A fenced block only opens when its fence starts a line. With the marker in
  # front of it the fence is mid-line, markdown stops seeing a fence, and the
  # reader gets three literal backticks over an unformatted block. Any command
  # whose whole reply is a code block hits this, and several do.
  # shellcheck disable=SC2016  # the backticks are a markdown fence inside JSON
  out="$(printf '{"session_id":"test-session","index":0,"delta":"```text\\nrow\\n```"}' | bash "$SCRIPTS/message-display.sh")"
  fenced="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.displayContent')"
  is "a leading code fence still starts its own line" "\`\`\`text" \
    "$(printf '%s\n' "$fenced" | sed -n '2p')"

  # The tilde fence is the other half of the same rule, and three spaces of
  # indent still opens one.
  out="$(printf '{"session_id":"test-session","index":0,"delta":"   ~~~\\nrow\\n~~~"}' | bash "$SCRIPTS/message-display.sh")"
  is "an indented tilde fence is treated the same" "   ~~~" \
    "$(printf '%s\n' "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.displayContent')" | sed -n '2p')"

  # The break must not cost every ordinary message a line. Prose keeps the
  # marker where it has always been, on the same line as the text.
  out="$(printf '{"session_id":"test-session","index":0,"delta":"Just prose."}' | bash "$SCRIPTS/message-display.sh")"
  is "prose keeps the marker on its own line" "1" \
    "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.displayContent' | wc -l | tr -d ' ')"

  # Whitespace around the colon is legal JSON, and the guard that decides
  # whether to look closer must not be fooled by it.
  out="$(printf '{"session_id":"test-session", "index" : 0 , "delta":"spaced"}' | bash "$SCRIPTS/message-display.sh")"
  contains "message-display accepts whitespace around the index" "spaced" \
    "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.displayContent')"

  # An index that is last in the object is followed by a brace, not a comma.
  out="$(printf '{"session_id":"test-session","delta":"trailing","index":0}' | bash "$SCRIPTS/message-display.sh")"
  contains "message-display accepts the index as the last key" "trailing" \
    "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.displayContent')"

  # A delta whose own text contains the pattern is not a first batch. The
  # guard is a filter, not a parser: it may say "look closer", never "stamp".
  #
  # In the payload those quotes arrive escaped, as \"index\":0, which does not
  # match the guard either -- so this case is rejected before any parse rather
  # than by it. Both routes end in the same place, and the assertion is about
  # the outcome, not which of the two got there. Do not "fix" it by unescaping
  # the delta: that would stop being valid JSON.
  out="$(printf '{"session_id":"test-session","index":7,"delta":"the payload said \\"index\\":0, apparently"}' \
    | bash "$SCRIPTS/message-display.sh")"
  is "message-display is not fooled by a delta that looks like an index" "" "$out"

  # A double-digit index must not match on its leading zero-free digits.
  out="$(printf '{"session_id":"test-session","index":10,"delta":"x"}' | bash "$SCRIPTS/message-display.sh")"
  is "message-display emits nothing for a two-digit index" "" "$out"

  # An absent index key is not proof of a later batch -- the downstream jq
  # call defaults a missing index to 0 -- so the guard must let it through
  # rather than treating "cannot tell" as "skip".
  out="$(printf '{"session_id":"test-session","delta":"no index field"}' | bash "$SCRIPTS/message-display.sh")"
  contains "message-display stamps a payload with no index key" "no index field" \
    "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.displayContent')"

  # Confirm the fix above did not simply disable the optimisation: a plain
  # later batch still emits nothing.
  out="$(printf '{"session_id":"test-session","index":5,"delta":"still skipped"}' | bash "$SCRIPTS/message-display.sh")"
  is "message-display still emits nothing for an ordinary later batch" "" "$out"

  # An index key present with a non-numeric value -- null, false, a quoted
  # "0" -- is coerced to 0 by the downstream `.index // 0`, the same as a
  # missing key. The guard must not mistake "present but not a digit" for
  # proof of a later batch.
  out="$(printf '{"session_id":"test-session","index":null,"delta":"null index"}' | bash "$SCRIPTS/message-display.sh")"
  contains "message-display stamps a payload with a null index" "null index" \
    "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.displayContent')"

  out="$(printf '{"session_id":"test-session","prompt":"hi"}' | bash "$SCRIPTS/user-prompt-submit.sh")"
  contains "user-prompt-submit injects context" "Message sent at local time" "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')"
  if [ -r "$(ct_state_dir)/test-session" ]; then
    pass "user-prompt-submit records the turn start"
  else
    fail "user-prompt-submit records the turn start" "state file exists" "missing"
  fi

  # An hour-scale offset is used deliberately: +1h03m stays stable for a whole
  # minute, so the assertion cannot flake when the hook reads a second after
  # the state file is written. A 134s offset did exactly that on Windows.
  printf '%s' "$(( $(date +%s) - 3780 ))" > "$(ct_state_dir)/test-session"
  out="$(printf '{"session_id":"test-session","index":0,"delta":"x"}' | bash "$SCRIPTS/message-display.sh" | jq -r '.hookSpecificOutput.displayContent')"
  contains "message-display renders elapsed time" "+1h03m" "$out"

  fresh 'ELAPSED=off'
  out="$(printf '{"session_id":"test-session","index":0,"delta":"x"}' | bash "$SCRIPTS/message-display.sh" | jq -r '.hookSpecificOutput.displayContent')"
  case "$out" in *"+"*) fail "ELAPSED=off hides the duration" "no + marker" "$out" ;; *) pass "ELAPSED=off hides the duration" ;; esac

  # A MARKER that renders empty -- here MARKER=%elapsed with ELAPSED=off --
  # passes validation, so nothing before this fix stopped a bare leading
  # space from being sent ahead of the delta on every message.
  fresh 'MARKER=%elapsed' 'ELAPSED=off' 'COLOR=none' 'IDLE_AFTER=0' 'DATE_ROLLOVER=off'
  out="$(printf '{"session_id":"test-session","index":0,"delta":"x"}' | bash "$SCRIPTS/message-display.sh" | jq -r '.hookSpecificOutput.displayContent')"
  is "an empty marker leaves no bare leading space" "x" "$out"

  # Date rollover: a stale date on file means the session crossed midnight.
  fresh 'COLOR=none' 'ELAPSED=off'
  printf '2000-01-01' > "$(ct_state_dir)/test-session.date"
  out="$(printf '{"session_id":"test-session","index":0,"delta":"x"}' | bash "$SCRIPTS/message-display.sh" | jq -r '.hookSpecificOutput.displayContent')"
  contains "date rollover adds the date after midnight" "$(date '+%b %d')" "$out"

  # The hook just recorded today, so a second message must not repeat it.
  # Asserted as the absence of a month name rather than by recomputing the
  # clock, which races with the hook by a second on a slow runner.
  out="$(printf '{"session_id":"test-session","index":0,"delta":"x"}' | bash "$SCRIPTS/message-display.sh" | jq -r '.hookSpecificOutput.displayContent')"
  lacks "date is not repeated on the same day" "$(date '+%b')" "$out"

  fresh 'COLOR=none' 'ELAPSED=off' 'DATE_ROLLOVER=off'
  printf '2000-01-01' > "$(ct_state_dir)/test-session.date"
  out="$(printf '{"session_id":"test-session","index":0,"delta":"x"}' | bash "$SCRIPTS/message-display.sh" | jq -r '.hookSpecificOutput.displayContent')"
  lacks "DATE_ROLLOVER=off suppresses the date" "$(date '+%b')" "$out"

  # %date is painted with TIME_COLOR, since the date is part of the clock --
  # not documented, not in schema.json, and not asserted anywhere before this,
  # so a previous review could (and did) replace the paint call with plain
  # COLOR and still see the whole suite report green.
  fresh 'COLOR=none' 'ELAPSED=off' 'TIME_COLOR=cyan' 'MARKER=%date' 'DATE_ROLLOVER=on'
  printf '2000-01-01' > "$(ct_state_dir)/test-session.date"
  out="$(printf '{"session_id":"test-session","index":0,"delta":"x"}' | bash "$SCRIPTS/message-display.sh" | jq -r '.hookSpecificOutput.displayContent')"
  contains "%date is painted in TIME_COLOR" "[36m" "$out"

  # Slow-turn colouring: the duration alone is painted, the rest is not.
  fresh 'COLOR=none' 'SLOW_AFTER=60' 'SLOW_COLOR=cyan' 'IDLE_AFTER=0' 'DATE_ROLLOVER=off'
  printf '%s' "$(( $(date +%s) - 3780 ))" > "$(ct_state_dir)/test-session"
  out="$(printf '{"session_id":"test-session","index":0,"delta":"x"}' | bash "$SCRIPTS/message-display.sh" | jq -r '.hookSpecificOutput.displayContent')"
  contains "a slow turn paints the duration" "[36m" "$out"

  fresh 'COLOR=none' 'SLOW_AFTER=0' 'IDLE_AFTER=0' 'DATE_ROLLOVER=off'
  printf '%s' "$(( $(date +%s) - 3780 ))" > "$(ct_state_dir)/test-session"
  out="$(printf '{"session_id":"test-session","index":0,"delta":"x"}' | bash "$SCRIPTS/message-display.sh" | jq -r '.hookSpecificOutput.displayContent')"
  lacks "SLOW_AFTER=0 leaves the duration unpainted" "[36m" "$out"

  fresh 'COLOR=none' 'SLOW_AFTER=99999' 'IDLE_AFTER=0' 'DATE_ROLLOVER=off'
  printf '%s' "$(( $(date +%s) - 3780 ))" > "$(ct_state_dir)/test-session"
  out="$(printf '{"session_id":"test-session","index":0,"delta":"x"}' | bash "$SCRIPTS/message-display.sh" | jq -r '.hookSpecificOutput.displayContent')"
  lacks "a turn under the threshold is unpainted" "[36m" "$out"

  # Idle divider. message-display.sh only draws and clears a staged gap now;
  # the measurement and the IDLE_AFTER gate live in ct_record_away, exercised
  # separately under "counting time away and failures".
  fresh 'COLOR=none' 'ELAPSED=off' 'DATE_ROLLOVER=off'
  printf '7200' > "$(ct_state_dir)/test-session.away"
  out="$(printf '{"session_id":"test-session","index":0,"delta":"x"}' | bash "$SCRIPTS/message-display.sh" | jq -r '.hookSpecificOutput.displayContent')"
  contains "an idle gap is marked" "2h later" "$out"

  # ct_take_away cleared what it printed, so a second message draws nothing.
  out="$(printf '{"session_id":"test-session","index":0,"delta":"x"}' | bash "$SCRIPTS/message-display.sh" | jq -r '.hookSpecificOutput.displayContent')"
  lacks "a fresh gap is not marked" "later" "$out"

  # No gap staged at all: nothing to draw.
  fresh 'COLOR=none' 'ELAPSED=off' 'DATE_ROLLOVER=off'
  out="$(printf '{"session_id":"test-session","index":0,"delta":"x"}' | bash "$SCRIPTS/message-display.sh" | jq -r '.hookSpecificOutput.displayContent')"
  lacks "no staged gap means no marker" "later" "$out"

  # Subagents.
  fresh 'COLOR=none' 'SUBAGENTS=off' 'IDLE_AFTER=0'
  out="$(printf '{"session_id":"test-session","index":0,"delta":"x","agent_id":"sub-1"}' | bash "$SCRIPTS/message-display.sh")"
  is "SUBAGENTS=off skips subagent messages" "" "$out"
  out="$(printf '{"session_id":"test-session","index":0,"delta":"x"}' | bash "$SCRIPTS/message-display.sh")"
  contains "SUBAGENTS=off still stamps the main conversation" "displayContent" "$out"
  fresh 'COLOR=none' 'SUBAGENTS=on' 'IDLE_AFTER=0'
  out="$(printf '{"session_id":"test-session","index":0,"delta":"x","agent_id":"sub-1"}' | bash "$SCRIPTS/message-display.sh")"
  contains "SUBAGENTS=on stamps subagent messages" "displayContent" "$out"

  echo
  echo "turn accounting"

  fresh
  base="$(ct_state_file "acct")"
  ct_clear_state "acct"
  mkdir -p "$(ct_state_dir)"

  # The helper on its own, before any hook drives it.
  printf '%s' "$(( $(date +%s) - 40 ))" > "$base"
  ct_close_turn "$base" "$(date +%s)"
  is_near "closing a turn adds it to the waiting total" 40 "$(ct_read_counter "$base.wait")" 2
  asserts "closing a turn marks it closed" test -r "$base.closed"

  # A hook can cause the model to run again, so a turn seeing two closes is a
  # case to survive rather than one to assume away.
  ct_close_turn "$base" "$(date +%s)"
  is_near "closing a closed turn adds nothing" 40 "$(ct_read_counter "$base.wait")" 2

  # An end that precedes the start means the turn drew no message of its own.
  ct_clear_state "acct"; mkdir -p "$(ct_state_dir)"
  now="$(date +%s)"
  printf '%s' "$now" > "$base"
  ct_close_turn "$base" "$(( now - 500 ))"
  is "a turn ending before it started adds nothing" "0" "$(ct_read_counter "$base.wait")"
  asserts "a turn ending before it started is still closed" test -r "$base.closed"
  # ...but not stamped with that earlier time. The next prompt measures the
  # user's break from .closed, so a turn abandoned before it drew anything --
  # straight into a long tool call, then an interrupt -- would hand the gap
  # its own whole duration on top of the real break. Closing no earlier than
  # the turn began keeps the figure to something that was actually a gap.
  is "and is closed no earlier than it began" "$now" "$(ct_read_counter "$base.closed")"

  # The same thing through the measurement that consumes it. A turn opened
  # 7000s ago spent 1800s in a tool and was then interrupted, drawing nothing,
  # so .last still points at the previous turn 8800s back. The break to report
  # is the 7000s since this turn opened, not the 8800s to a message from
  # before the user's own prompt.
  ct_clear_state "acct"; mkdir -p "$(ct_state_dir)"
  now="$(date +%s)"
  printf '%s' "$(( now - 7000 ))" > "$base"
  printf '%s' "$(( now - 8800 ))" > "$base.last"
  ct_close_turn "$base" "$(ct_read_counter "$base.last")"
  CT_IDLE_AFTER=3600 ct_record_away "acct" "$now"
  is "an abandoned turn is not counted as time away" "7000" "$(ct_read_counter "$base.away")"

  ct_clear_state "acct"; mkdir -p "$(ct_state_dir)"
  ct_close_turn "$base" "$(date +%s)"
  is "closing a turn that never started adds nothing" "0" "$(ct_read_counter "$base.wait")"

  # One prompt is one turn, however many messages it produces.
  ct_clear_state "acct"; mkdir -p "$(ct_state_dir)"
  printf '{"session_id":"acct"}' | bash "$SCRIPTS/user-prompt-submit.sh" >/dev/null
  is "a prompt counts one turn" "1" "$(ct_read_counter "$base.turns")"

  # Messages no longer accumulate waiting: the marker hook draws a marker.
  printf '%s' "$(( $(date +%s) - 25 ))" > "$base"
  printf '{"session_id":"acct","index":0,"delta":"x"}' | bash "$SCRIPTS/message-display.sh" >/dev/null
  printf '{"session_id":"acct","index":0,"delta":"x"}' | bash "$SCRIPTS/message-display.sh" >/dev/null
  is "messages do not accumulate waiting" "0" "$(ct_read_counter "$base.wait")"
  is "extra messages do not add turns" "1" "$(ct_read_counter "$base.turns")"

  # Stop closes it, once, for the whole turn. The turn start is re-stamped
  # immediately before the call: the assertions above spawn several processes,
  # and on a slow runner that harness time lands inside the interval stop.sh
  # measures, which is what made these four fail on Windows and nowhere else.
  # Re-stamping measures the hook, not the test.
  printf '%s' "$(( $(date +%s) - 25 ))" > "$base"
  printf '{"session_id":"acct","hook_event_name":"Stop"}' | bash "$SCRIPTS/stop.sh"
  is_near "Stop records the whole turn as waiting" 25 "$(ct_read_counter "$base.wait")" 2
  printf '{"session_id":"acct","hook_event_name":"Stop"}' | bash "$SCRIPTS/stop.sh"
  is_near "a second Stop adds nothing" 25 "$(ct_read_counter "$base.wait")" 2

  # A second prompt starts a fresh turn, and finds nothing left to reconcile.
  printf '{"session_id":"acct"}' | bash "$SCRIPTS/user-prompt-submit.sh" >/dev/null
  is "a second prompt counts a second turn" "2" "$(ct_read_counter "$base.turns")"
  is_near "a prompt after a clean close adds nothing" 25 "$(ct_read_counter "$base.wait")" 2
  if [ -e "$base.closed" ]; then
    fail "a new prompt reopens the turn" "no .closed file" "still closed"
  else
    pass "a new prompt reopens the turn"
  fi
  printf '%s' "$(( $(date +%s) - 30 ))" > "$base"
  printf '{"session_id":"acct","hook_event_name":"StopFailure"}' | bash "$SCRIPTS/stop.sh"
  is_near "StopFailure closes a turn too" 55 "$(ct_read_counter "$base.wait")" 3

  # An interrupted turn never sees a Stop. The next prompt reconciles it using
  # the last message drawn, so it contributes the part that was observed.
  #
  # Both offsets come from one reading of the clock. Taking two would let a
  # second tick between them and make the difference 39 or 41, which is a flake
  # rather than a bug, and this assertion is exact because nothing in it is
  # measured against the clock at the moment the hook runs.
  ct_clear_state "acct"; mkdir -p "$(ct_state_dir)"
  printf '{"session_id":"acct"}' | bash "$SCRIPTS/user-prompt-submit.sh" >/dev/null
  now="$(date +%s)"
  printf '%s' "$(( now - 60 ))" > "$base"
  printf '%s' "$(( now - 20 ))" > "$base.last"
  printf '{"session_id":"acct"}' | bash "$SCRIPTS/user-prompt-submit.sh" >/dev/null
  is "an interrupted turn contributes what was observed" "40" "$(ct_read_counter "$base.wait")"

  # A turn interrupted before it drew anything has nothing to contribute.
  ct_clear_state "acct"; mkdir -p "$(ct_state_dir)"
  printf '{"session_id":"acct"}' | bash "$SCRIPTS/user-prompt-submit.sh" >/dev/null
  printf '%s' "$(( $(date +%s) - 60 ))" > "$base"
  printf '{"session_id":"acct"}' | bash "$SCRIPTS/user-prompt-submit.sh" >/dev/null
  is "a turn that drew nothing contributes nothing" "0" "$(ct_read_counter "$base.wait")"

  # IDLE_AFTER=0 switches off the divider and the .idle total, but the
  # timestamp message-display.sh stamps every message with is not that
  # feature -- it is the evidence an interrupted turn is reconciled from, so
  # turning idle marking off must not turn off the stamp itself.
  fresh 'IDLE_AFTER=0'
  ct_clear_state "acct"; mkdir -p "$(ct_state_dir)"
  printf '{"session_id":"acct"}' | bash "$SCRIPTS/user-prompt-submit.sh" >/dev/null
  printf '%s' "$(( $(date +%s) - 60 ))" > "$base"
  printf '{"session_id":"acct","index":0,"delta":"x"}' | bash "$SCRIPTS/message-display.sh" >/dev/null
  asserts "message-display stamps .last even with IDLE_AFTER=0" test -r "$base.last"
  printf '%s' "$(( $(date +%s) - 20 ))" > "$base.last"
  printf '{"session_id":"acct"}' | bash "$SCRIPTS/user-prompt-submit.sh" >/dev/null
  is_near "an interrupted turn still contributes with IDLE_AFTER=0" 40 "$(ct_read_counter "$base.wait")" 2
  fresh

  # The session can end mid-turn too, and that is the same reconciliation.
  # One reading of the clock again, for the same reason as above.
  ct_clear_state "acct"; mkdir -p "$(ct_state_dir)"
  now="$(date +%s)"
  printf '%s' "$(( now - 900 ))" > "$base.start"
  printf '1' > "$base.turns"
  printf '%s' "$(( now - 60 ))" > "$base"
  printf '%s' "$(( now - 20 ))" > "$base.last"
  out="$(printf '{"session_id":"acct"}' | bash "$SCRIPTS/session-end.sh" | jq -r '.systemMessage')"
  contains "session end closes a turn still open" "40s of it waiting" "$out"

  # The whole hook, not just the counter helper: an environment carrying
  # inherit_errexit must not leave the marker without its duration. Every
  # state file this plugin writes lacks a trailing newline, so the first read
  # in the hook is the one that would abort it.
  ct_clear_state "acct"; mkdir -p "$(ct_state_dir)"
  printf '%s' "$(( $(date +%s) - 134 ))" > "$base"
  out="$(printf '{"session_id":"acct","index":0,"delta":"x"}' \
         | env BASHOPTS=inherit_errexit bash "$SCRIPTS/message-display.sh" 2>/dev/null)"
  # The seeded 134s can tick over to 135 between the write and the hook reading
  # it, which a slow runner does often enough to have failed CI on Windows at
  # +2m15s. Either rendering is the clock moving rather than the duration being
  # wrong, so both are accepted, and the pair still pins the value to the
  # seeded file: a hook that lost the duration prints no +NmNNs at all, which
  # is the regression this case is here for.
  errx_marker="$(strip_ansi "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.displayContent')")"
  case "$errx_marker" in
    *"+2m14s"*|*"+2m15s"*)
      pass "the marker still shows a duration under inherit_errexit" ;;
    *) fail "the marker still shows a duration under inherit_errexit" \
            "something containing '+2m14s' or '+2m15s'" "$errx_marker" ;;
  esac
  fresh

  # The ordering every normal session takes: Stop closes the turn, then
  # SessionEnd runs behind it. In production .last already holds a real value
  # by the time Stop fires, because every message drawn stamps it first, so
  # this sets .last to a value strictly after the turn started and no later
  # than now to match. Without that, SessionEnd's reconciliation call would
  # pass ended=0 and could never double-count regardless of the .closed
  # guard -- .last is what makes this exercise the guard at all.
  #
  # Both offsets come from one reading of the clock, and the comparisons use
  # the values Stop actually wrote rather than a value predicted from the
  # clock, so they are exact without needing a tolerance.
  ct_clear_state "acct"; mkdir -p "$(ct_state_dir)"
  now="$(date +%s)"
  printf '%s' "$(( now - 900 ))" > "$base.start"
  printf '1' > "$base.turns"
  printf '%s' "$(( now - 45 ))" > "$base"
  printf '%s' "$(( now - 10 ))" > "$base.last"
  printf '{"session_id":"acct","hook_event_name":"Stop"}' | bash "$SCRIPTS/stop.sh"
  started="$(cat "$base")"
  waited="$(ct_read_counter "$base.wait")"
  is "Stop's .closed holds the epoch the turn ended" "$(( started + waited ))" "$(cat "$base.closed")"
  out="$(printf '{"session_id":"acct"}' | bash "$SCRIPTS/session-end.sh" | jq -r '.systemMessage')"
  contains "SessionEnd after Stop does not double-count" "$(ct_format_duration "$waited") of it waiting" "$out"

  # The hook is silent even when it does have work to do: it writes state and
  # says nothing. Asserted under a config where it runs, so that it cannot pass
  # merely by having exited early.
  fresh
  ct_clear_state "acct"; mkdir -p "$(ct_state_dir)"
  printf '%s' "$(( $(date +%s) - 40 ))" > "$base"
  out="$(printf '{"session_id":"acct","hook_event_name":"Stop"}' | bash "$SCRIPTS/stop.sh")"
  is "stop emits nothing" "" "$out"
  is_near "stop did its work while staying silent" 40 "$(ct_read_counter "$base.wait")" 2

  # Switched off, the hook still records: the counter is shared with the
  # history, and SUMMARY gates the report rather than the measurement. This
  # assertion used to expect 0, which was the bug -- a session recorded with
  # HISTORY=on and SUMMARY=off carried a waiting figure of zero.
  fresh 'SUMMARY=off'
  printf '%s' "$(( $(date +%s) - 40 ))" > "$base"
  printf '{"session_id":"acct","hook_event_name":"Stop"}' | bash "$SCRIPTS/stop.sh"
  is_near "SUMMARY=off still records waiting" 40 "$(ct_read_counter "$base.wait")" 2

  fresh 'ENABLED=off'
  printf '%s' "$(( $(date +%s) - 40 ))" > "$base"
  printf '{"session_id":"acct","hook_event_name":"Stop"}' | bash "$SCRIPTS/stop.sh"
  is "ENABLED=off records no waiting" "0" "$(ct_read_counter "$base.wait")"

  # --- the subagent guard ---------------------------------------------------
  #
  # Stop closes the USER's turn, and a subagent completing is not the end of
  # one. A payload carrying an agent_id is therefore a complete no-op: exit 0,
  # nothing on stdout, and the turn left exactly as it was for the Stop that
  # really does end it. Anything less and a session full of subagents reports
  # the user waiting through turns that were never theirs.

  fresh
  ct_clear_state "acct"; mkdir -p "$(ct_state_dir)"
  started="$(( $(date +%s) - 30 ))"
  printf '%s' "$started" > "$base"
  out="$(printf '{"session_id":"acct","agent_id":"sub-1","hook_event_name":"Stop"}' \
         | bash "$SCRIPTS/stop.sh")"
  rc=$?
  is "a subagent Stop exits 0"          "0" "$rc"
  is "a subagent Stop emits nothing"    ""  "$out"
  is "a subagent Stop records no waiting" "0" "$(ct_read_counter "$base.wait")"
  refutes "a subagent Stop leaves the turn open" test -e "$base.closed"
  is "a subagent Stop does not move the turn's start" "$started" "$(ct_read_counter "$base")"

  # ...and the turn it declined to close is still closable afterwards, which
  # is the whole point of leaving it open rather than merely of writing less.
  printf '{"session_id":"acct","hook_event_name":"Stop"}' | bash "$SCRIPTS/stop.sh"
  is_near "the real Stop still closes the turn the subagent left alone" 30 \
     "$(ct_read_counter "$base.wait")" 2

  # An explicitly empty agent_id is the main conversation, not a subagent.
  # The three fields are packed into one \x1f-joined string precisely so an
  # empty one cannot be collapsed away, and this is the half of that which
  # would break if the guard tested the wrong emptiness.
  fresh
  ct_clear_state "acct"; mkdir -p "$(ct_state_dir)"
  printf '%s' "$(( $(date +%s) - 30 ))" > "$base"
  printf '{"session_id":"acct","agent_id":"","hook_event_name":"Stop"}' \
    | bash "$SCRIPTS/stop.sh"
  is_near "an empty agent_id closes the turn" 30 "$(ct_read_counter "$base.wait")" 2
  asserts "an empty agent_id marks the turn closed" test -e "$base.closed"

  # No agent_id key at all takes the `// ""` default, which must land in the
  # same slot an empty string would: a join order that put it anywhere else
  # would leave a session id or a cwd sitting in agent_id, and every main
  # conversation would then stop being measured.
  fresh
  ct_clear_state "acct"; mkdir -p "$(ct_state_dir)"
  printf '%s' "$(( $(date +%s) - 30 ))" > "$base"
  printf '{"session_id":"acct","hook_event_name":"Stop"}' | bash "$SCRIPTS/stop.sh"
  is_near "an absent agent_id closes the turn" 30 "$(ct_read_counter "$base.wait")" 2

  # The field-order defect message-display.sh already carried: split on IFS
  # whitespace, an empty middle field collapses and shifts the next one into
  # its place. Here that would empty agent_id and close a subagent's turn.
  fresh
  ct_clear_state "acct"; mkdir -p "$(ct_state_dir)"
  printf '%s' "$(( $(date +%s) - 30 ))" > "$base"
  out="$(printf '{"session_id":"acct","cwd":"","agent_id":"sub-1"}' \
         | bash "$SCRIPTS/stop.sh")"
  is "an empty cwd does not shift agent_id out of position" "0" \
     "$(ct_read_counter "$base.wait")"
  is "a subagent behind an empty cwd still emits nothing" "" "$out"
  refutes "a subagent behind an empty cwd leaves the turn open" test -e "$base.closed"

  # The same shift in the other direction: a populated cwd with an empty
  # agent_id after it. The cwd must still reach ct_load_config, so the project
  # layer under it decides whether the turn is recorded.
  SUBG="$WORK/subguard"
  rm -rf "$SUBG"
  mkdir -p "$SUBG/home/.claude" "$SUBG/home/on-repo/.claude" \
           "$SUBG/home/off-repo/.claude" "$SUBG/home/plain"
  printf 'ENABLED=off\n' > "$SUBG/home/.claude/claude-timestamp.conf"
  printf 'ENABLED=on\n'  > "$SUBG/home/on-repo/.claude/claude-timestamp.conf"
  printf 'ENABLED=off\n' > "$SUBG/home/off-repo/.claude/claude-timestamp.conf"

  stop_in() {
    # $1 = cwd reported in the payload, $2 = agent_id. CLAUDE_TIMESTAMP_CONFIG
    # names one exact file and disables the project layer, so it has to go.
    ( unset CLAUDE_TIMESTAMP_CONFIG
      HOME="$SUBG/home"
      printf '{"session_id":"acct","cwd":"%s","agent_id":"%s"}' "$1" "$2" \
        | bash "$SCRIPTS/stop.sh" )
  }

  fresh
  ct_clear_state "acct"; mkdir -p "$(ct_state_dir)"
  printf '%s' "$(( $(date +%s) - 30 ))" > "$base"
  stop_in "$SUBG/home/on-repo" ""
  is_near "a populated cwd with an empty agent_id closes the turn" 30 \
     "$(ct_read_counter "$base.wait")" 2

  # The control for the assertion above: the account config says off, so the
  # turn was closed only because the project file at that cwd was found. A cwd
  # with no project layer falls back and records nothing.
  fresh
  ct_clear_state "acct"; mkdir -p "$(ct_state_dir)"
  printf '%s' "$(( $(date +%s) - 30 ))" > "$base"
  stop_in "$SUBG/home/plain" ""
  is "a cwd with no project layer falls back to the account config" "0" \
     "$(ct_read_counter "$base.wait")"

  # The guard sits above ct_load_config, so no configuration can be what makes
  # it hold. Under a project file that switches the plugin ON -- the one
  # setting that would otherwise have the hook write -- a subagent payload
  # still writes nothing.
  fresh
  ct_clear_state "acct"; mkdir -p "$(ct_state_dir)"
  printf '%s' "$(( $(date +%s) - 30 ))" > "$base"
  out="$(stop_in "$SUBG/home/on-repo" "sub-1")"
  is "a subagent is skipped under a project config that enables the hook" "0" \
     "$(ct_read_counter "$base.wait")"
  is "and says nothing while doing it" "" "$out"
  refutes "and leaves the turn open" test -e "$base.closed"

  # And under a project file that switches it OFF, where the config would have
  # stopped the write anyway: the state is untouched either way.
  fresh
  ct_clear_state "acct"; mkdir -p "$(ct_state_dir)"
  printf '%s' "$(( $(date +%s) - 30 ))" > "$base"
  # Every name in the state directory is one this test wrote, so ls reads them
  # safely; find -printf, the usual replacement, is GNU-only and the suite runs
  # on BSD and Git Bash too.
  # shellcheck disable=SC2012
  state_ls() { ls "$(ct_state_dir)" | sort | tr '\n' ' '; }
  before="$(state_ls)"
  out="$(stop_in "$SUBG/home/off-repo" "sub-1")"
  is "a subagent under ENABLED=off writes no new state file" "$before" \
     "$(state_ls)"
  is "a subagent under ENABLED=off emits nothing" "" "$out"
  is "a subagent under ENABLED=off records no waiting" "0" \
     "$(ct_read_counter "$base.wait")"

  fresh
  ct_clear_state "acct"

  echo
  echo "session summary"

  fresh
  base="$(ct_state_file "summary-session")"
  mkdir -p "$(ct_state_dir)"
  printf '%s' "$(( $(date +%s) - 5400 ))" > "$base.start"
  printf '3'    > "$base.turns"
  printf '754'  > "$base.wait"
  out="$(printf '{"session_id":"summary-session"}' | bash "$SCRIPTS/session-end.sh" | jq -r '.systemMessage')"
  contains "summary reports the turn count" "3 turns" "$out"
  contains "summary never reports more waiting than the session lasted" "1h30m" "$out"
  contains "summary reports time spent waiting" "12m34s of it waiting" "$out"
  if [ -e "$base.turns" ]; then
    fail "session end clears its state" "no state files" "state remains"
  else
    pass "session end clears its state"
  fi

  # One turn must not be reported as "1 turns".
  printf '%s' "$(( $(date +%s) - 60 ))" > "$base.start"
  printf '1' > "$base.turns"; printf '5' > "$base.wait"
  out="$(printf '{"session_id":"summary-session"}' | bash "$SCRIPTS/session-end.sh" | jq -r '.systemMessage')"
  contains "a single turn is singular" "1 turn," "$out"

  # A session with nothing recorded has nothing to say.
  out="$(printf '{"session_id":"never-used"}' | bash "$SCRIPTS/session-end.sh")"
  is "an empty session reports nothing" "" "$out"

  fresh 'SUMMARY=off'
  printf '%s' "$(( $(date +%s) - 60 ))" > "$base.start"
  printf '2' > "$base.turns"; printf '5' > "$base.wait"
  out="$(printf '{"session_id":"summary-session"}' | bash "$SCRIPTS/session-end.sh")"
  is "SUMMARY=off reports nothing" "" "$out"

  fresh 'INJECT_CONTEXT=false'
  out="$(printf '{"session_id":"test-session","prompt":"hi"}' | bash "$SCRIPTS/user-prompt-submit.sh")"
  is "INJECT_CONTEXT=false injects nothing" "" "$out"

  # Everything optional is off so this asserts only on the time rendering
  # itself, independent of state left behind by earlier cases.
  fresh 'COLOR=none' 'DISPLAY_FORMAT=short' 'TZ=UTC' 'ELAPSED=off' 'DATE_ROLLOVER=off' 'IDLE_AFTER=0'
  # Bracketed by two readings of the clock and accepting either, so a minute
  # boundary crossed mid-test cannot fail it.
  before="[$(TZ=UTC date '+%H:%M')] x"
  out="$(printf '{"session_id":"test-session","index":0,"delta":"x"}' | bash "$SCRIPTS/message-display.sh" | jq -r '.hookSpecificOutput.displayContent')"
  after="[$(TZ=UTC date '+%H:%M')] x"
  if [ "$out" = "$before" ] || [ "$out" = "$after" ]; then
    pass "config drives the rendered marker end to end"
  else
    fail "config drives the rendered marker end to end" "$before" "$out"
  fi

  out="$(printf '{"session_id":"s"}' | bash "$SCRIPTS/session-start.sh")"
  is "session-start is quiet once configured" "" "$out"

  CLAUDE_TIMESTAMP_CONFIG="$WORK/does-not-exist.conf" out="$(printf '{"session_id":"s"}' | bash "$SCRIPTS/session-start.sh")"
  contains "session-start points a new user at /timestamps" "/timestamps" "$out"

  # SessionStart has three things it might say, and a hook returns one object.
  # A project config with a bad key while the user has no config of their own
  # triggers two of them at once.
  SS="$WORK/sessionstart"
  rm -rf "$SS"; mkdir -p "$SS/proj/.claude"
  printf 'COLOR=banana\nSLOW_AFTER=soon\n' > "$SS/proj/.claude/claude-timestamp.conf"
  out="$( unset CLAUDE_TIMESTAMP_CONFIG
          HOME="$SS"
          export HOME
          printf '{"cwd":"%s/proj"}' "$SS" | bash "$SCRIPTS/session-start.sh" )"
  is "session start: emits exactly one JSON object" "1" "$(printf '%s' "$out" | jq -s 'length')"
  contains "session start: the object mentions the bad colour" "COLOR=banana" "$out"
  contains "session start: and the first-run pointer"          "/timestamps"  "$out"
else
  echo "  skip jq not installed, hook tests not run"
fi

echo
echo "stale PreToolUse binding"

# ad31d05 removed the PreToolUse binding and pre-tool-use.sh together, because
# post-tool-use.sh now reads duration_ms from the payload instead. A session
# already running when that update lands still holds the old binding, though
# -- hooks are bound once at session start -- and keeps trying to exec this
# path on every tool call until the user restarts. The shim exists purely to
# give that stale binding something harmless to run. This test is what stops
# someone deleting the shim before every supported version has stopped
# binding PreToolUse; retire the test along with the shim, together.
asserts "the PreToolUse compatibility shim still exists" test -e "$SCRIPTS/pre-tool-use.sh"
# Redirected from a file rather than piped in. The shim exits without ever
# reading stdin, so a writer on the other end of a pipe can lose the race and
# die of SIGPIPE, and pipefail then reports the writer's 141 as the pipeline's
# status. That says nothing about the shim, which is what this measures.
printf '{"session_id":"s","tool_use_id":"t1","tool_name":"Bash","hook_event_name":"PreToolUse","tool_input":{"command":"ls -la"}}' \
  > "$WORK/shim.in"
shim_out="$(bash "$SCRIPTS/pre-tool-use.sh" < "$WORK/shim.in" 2>"$WORK/shim.err")"
shim_rc=$?
is "the shim exits 0 on a realistic PreToolUse payload" "0" "$shim_rc"
is "the shim prints nothing on stdout"                  "" "$shim_out"
is "the shim prints nothing on stderr"                  "" "$(cat "$WORK/shim.err")"

echo
echo "setup"

fresh 'COLOR=dim' 'TZ=UTC'
bash "$SCRIPTS/setup.sh" --color=cyan >/dev/null
ct_load_config
is "a flag changes its own setting" "cyan" "$CT_COLOR"
is "a flag leaves other settings alone" "UTC" "$CT_TZ"

bash "$SCRIPTS/setup.sh" --tz=local >/dev/null
ct_load_config
is "--tz=local clears the pinned timezone" "" "$CT_TZ"

refutes "rejects an unknown color" bash "$SCRIPTS/setup.sh" --color=banana
refutes "rejects an unknown timezone" bash "$SCRIPTS/setup.sh" --tz=Mars/Olympus
refutes "rejects a non on/off elapsed value" bash "$SCRIPTS/setup.sh" --elapsed=maybe
refutes "rejects an unknown flag" bash "$SCRIPTS/setup.sh" --nonsense
contains "--show prints the config path" "$(ct_tilde "$CLAUDE_TIMESTAMP_CONFIG")" "$(bash "$SCRIPTS/setup.sh" --show)"

# doctor() gained marker and part-colour rows when MARKER was added; --show is
# a second surface that also claims to list every setting, and was left behind.
fresh 'MARKER=%time{ %elapsed}'
contains "--show mentions the marker template" '%time{ %elapsed}' "$(bash "$SCRIPTS/setup.sh" --show)"
contains "--help lists the flags" "--elapsed" "$(bash "$SCRIPTS/setup.sh" --help)"
bash "$SCRIPTS/setup.sh" --date-rollover=off >/dev/null
ct_load_config
is "--date-rollover is accepted" "off" "$CT_DATE_ROLLOVER"
refutes "rejects a non on/off date-rollover value" bash "$SCRIPTS/setup.sh" --date-rollover=sometimes

bash "$SCRIPTS/setup.sh" --slow-after=90 --slow-color=cyan --idle-after=600 --summary=off --subagents=off >/dev/null
ct_load_config
is "--slow-after is accepted"  "90"    "$CT_SLOW_AFTER"
is "--slow-color is accepted"  "cyan"  "$CT_SLOW_COLOR"
is "--idle-after is accepted"  "600"   "$CT_IDLE_AFTER"
is "--summary is accepted"     "off"   "$CT_SUMMARY"
is "--subagents is accepted"   "off"   "$CT_SUBAGENTS"
refutes "rejects a non-numeric slow-after" bash "$SCRIPTS/setup.sh" --slow-after=soon
refutes "rejects a non-numeric idle-after" bash "$SCRIPTS/setup.sh" --idle-after=later
refutes "rejects an unknown slow colour"   bash "$SCRIPTS/setup.sh" --slow-color=banana
bash "$SCRIPTS/setup.sh" --tool-timing=on >/dev/null
ct_load_config
is "--tool-timing is accepted" "on" "$CT_TOOL_TIMING"
refutes "rejects a non on/off tool-timing value" bash "$SCRIPTS/setup.sh" --tool-timing=sometimes

# The two format flags were the only ones that reached the config file without
# passing their validator. A name that is neither a preset nor a strftime
# string is a typo, and writing it means the loader replaces it with the
# default at the next session start -- hours after the flag reported success.
refutes "rejects an unusable display format" bash "$SCRIPTS/setup.sh" --display=nonsense
refutes "rejects an unusable context format" bash "$SCRIPTS/setup.sh" --context=nonsense

# A control character is worse than a typo. write_config interpolates a value
# into KEY=value with no escaping, so a newline writes a second line that the
# parser reads back as a real setting -- one the caller never named, and one
# that lands after the key it came from, so it wins.
fresh 'ENABLED=on'
refutes "rejects a newline in a display format" \
  bash "$SCRIPTS/setup.sh" --display=$'%H:%M\nENABLED=off'
refutes "rejects a newline in a context format" \
  bash "$SCRIPTS/setup.sh" --context=$'%H:%M\nENABLED=off'
ct_load_config
is "a rejected format cannot smuggle a second setting into the file" "on" "$CT_ENABLED"

# The same thing for every flag, driven from the table setup.sh itself parses.
#
# No validator accepts a newline: the enums and the numeric checks take nothing
# outside their own shape, and the three free-text keys refuse a control
# character outright. So every flag must refuse one, and a flag that reaches
# the config file without asking its validator cannot -- write_config
# interpolates into KEY=value with no escaping, so the newline writes a second
# line the parser reads back as a real setting.
#
# Written against the whole flag set rather than against the two that happened
# to be wrong, so flag twenty-one is covered the day it is added.
fresh 'ENABLED=on'
flag_table="$(sed -n '/^CT_FLAG_TABLE="$/,/^"$/p' "$SCRIPTS/setup.sh" | sed '1d;$d')"
is "every setting has a flag in the table" "21" \
  "$(printf '%s\n' "$flag_table" | grep -c '^[a-z]')"
# shellcheck disable=SC2034  # t_rest is read to consume the rest of the row
while read -r t_flag t_rest; do
  [ -n "$t_flag" ] || continue
  refutes "flag --$t_flag refuses a value carrying a newline" \
    bash "$SCRIPTS/setup.sh" "--$t_flag=$(printf 'x\nENABLED=off')"
done <<FLAGTABLE
$flag_table
FLAGTABLE
ct_load_config
is "and no flag smuggled a second setting into the file" "on" "$CT_ENABLED"

fresh
bash "$SCRIPTS/setup.sh" --marker='%time' >/dev/null
ct_load_config
is "setup: writes a marker template" "%time" "$CT_MARKER_TEMPLATE"

# The parser trims whitespace off both ends of a value and then unwraps a
# matching pair of quotes. A marker's own edges can be meaningful, so a value
# that needs either of those preserved must be written quoted, or it comes
# back changed. Ordinary values (no edge space, no leading quote) must still
# write bare, so an existing config file is not churned on the next write.
fresh
bash "$SCRIPTS/setup.sh" --marker='%time ' >/dev/null
ct_load_config
is "config: a trailing space in a marker survives the round trip" '%time ' "$CT_MARKER_TEMPLATE"
is "config: a marker needing it is written quoted" "1" \
  "$(grep -c "^MARKER='%time '\$" "$CLAUDE_TIMESTAMP_CONFIG")"

fresh
bash "$SCRIPTS/setup.sh" --display=' %H:%M' >/dev/null
ct_load_config
is "config: a leading space in a format string survives the round trip" ' %H:%M' "$CT_DISPLAY_FORMAT"

fresh
bash "$SCRIPTS/setup.sh" --marker='"%time"' >/dev/null
ct_load_config
is "config: a marker containing quote characters survives the round trip" '"%time"' "$CT_MARKER_TEMPLATE"

fresh
bash "$SCRIPTS/setup.sh" --marker="'twas the night" >/dev/null
ct_load_config
is "config: a marker starting with a quote character survives the round trip" "'twas the night" "$CT_MARKER_TEMPLATE"

fresh
bash "$SCRIPTS/setup.sh" --color=cyan >/dev/null
is "config: an unremarkable marker still writes unquoted" "1" \
  "$(grep -c '^MARKER=\[' "$CLAUDE_TIMESTAMP_CONFIG")"

# ct_load_config reads this file from five hooks, and message-display reads it
# on every displayed message, so a writer that truncates in place can be caught
# mid-write: the reader sees a partial file, silently falls back to defaults
# for the keys not yet written, and draws one message in the wrong timezone or
# colour. A reader that opened the file before the write stands in for that
# race deterministically -- with a truncate-in-place writer its descriptor is
# emptied under it, and with a rename it keeps the complete previous file.
fresh 'COLOR=cyan'
exec 9< "$CLAUDE_TIMESTAMP_CONFIG"
bash "$SCRIPTS/setup.sh" --color=red >/dev/null
opened="$(cat <&9)"
exec 9<&-
contains "config: a write never truncates a file already being read" "COLOR=cyan" "$opened"
ct_load_config
is "config: and the new value did land" "red" "$CT_COLOR"

fresh
bash "$SCRIPTS/setup.sh" --time-color=cyan --elapsed-color=green --tool-color=gray >/dev/null
ct_load_config
is "setup: writes the time colour"    "cyan"  "$CT_TIME_COLOR"
is "setup: writes the elapsed colour" "green" "$CT_ELAPSED_COLOR"
is "setup: writes the tool colour"    "gray"  "$CT_TOOL_COLOR"

# A part colour is empty by default and that emptiness is meaningful --
# "inherit COLOR" -- so the CLI needs a way to set it back once it has been
# pointed at a real colour, the same way --tz=local resets TZ.
bash "$SCRIPTS/setup.sh" --time-color=inherit >/dev/null
ct_load_config
is "setup: --time-color=inherit clears the time colour" "" "$CT_TIME_COLOR"

# A bare --time-color= is ambiguous with "not named on the command line" (both
# split to an empty string), so it is rejected rather than silently doing
# nothing -- the same silent-success class this fix exists to close.
bash "$SCRIPTS/setup.sh" --time-color=cyan >/dev/null
refutes "setup: a bare --time-color= is rejected" \
  bash "$SCRIPTS/setup.sh" --time-color=
bash "$SCRIPTS/setup.sh" --time-color= >/dev/null 2>&1
ct_load_config
is "setup: a rejected bare --time-color= changes nothing" "cyan" "$CT_TIME_COLOR"

fresh 'MARKER=%time'
refutes "setup: refuses an invalid template" \
  bash "$SCRIPTS/setup.sh" --marker='%elapsd'
ct_load_config
is "setup: and leaves the old one alone" "%time" "$CT_MARKER_TEMPLATE"

# Unlike a bare --time-color=, a bare --marker= is not rejected: an empty
# template is already a legal, meaningful value (ct_is_valid_marker accepts
# it, and message-display.sh emits no prefix at all for one), so the CLI
# honours it instead of erroring -- the same way --tz=local sets an empty TZ.
# It must still not be the silent no-op the finding described: CT_MARKER_TEMPLATE
# actually changes and the write still reports success.
fresh 'MARKER=%time'
asserts "setup: a bare --marker= is accepted, not rejected" \
  bash "$SCRIPTS/setup.sh" --marker=
ct_load_config
is "setup: a bare --marker= clears the template" "" "$CT_MARKER_TEMPLATE"

# End to end: a newline embedded in the flag value must be refused rather than
# written -- otherwise it lands as a second config line the loader reads back
# as a real setting (see "marker: a newline is rejected" above).
out="$( CLAUDE_TIMESTAMP_CONFIG="$WORK/inject.conf" \
        bash "$SCRIPTS/setup.sh" --marker="$(printf 'x\nENABLED=off')" 2>&1 )" && rc=0 || rc=$?
is "setup: refuses a marker containing a newline" "2" "$rc"
is "setup: and writes nothing" "0" \
   "$( [ -e "$WORK/inject.conf" ] && wc -l < "$WORK/inject.conf" | tr -d ' ' || echo 0 )"

echo
echo "invalid value messages"

# _ct_say_invalid owns the failure message for every validator named in
# CT_FLAG_TABLE, which is what makes the flag path and the wizard say the same
# thing about the same bad value. One arm per validator, pinned here, because
# an arm that stops naming the setting or stops echoing the offending value
# leaves the /timestamps command relaying a sentence the user cannot act on.
#
# Every case reads stderr with `2>&1 >/dev/null`, so an assertion here is about
# what the user is told and never about what a successful write would have
# printed. That stdout is left empty is a separate claim, asserted on its own
# below: stdout carries the preview of a successful write, and a refusal mixed
# into it is one the caller cannot tell apart from success.
fresh
# shellcheck disable=SC2069  # the order is the point: stderr to the capture, stdout to /dev/null
invalid() {
  CLAUDE_TIMESTAMP_CONFIG="$WORK/invalid.conf" \
    bash "$SCRIPTS/setup.sh" "$@" 2>&1 >/dev/null
}

is "invalid: ct_is_onoff names the flag, the rule and the value" \
   "--enabled must be 'on' or 'off', got 'maybe'." \
   "$(invalid --enabled=maybe)"
out="$(CLAUDE_TIMESTAMP_CONFIG="$WORK/invalid.conf" \
       bash "$SCRIPTS/setup.sh" --enabled=maybe >/dev/null 2>&1)" && rc=0 || rc=$?
is "invalid: and refusing a value exits 2" "2" "$rc"

# --inject-context is the one flag spelled true/false rather than on/off, so
# its message must not tell the user to write "on".
is "invalid: ct_is_bool asks for true/false, not on/off" \
   "--inject-context must be 'true' or 'false', got 'yes'." \
   "$(invalid --inject-context=yes)"

is "invalid: ct_is_seconds is labelled by the flag as typed" \
   "--slow-after must be a whole number of seconds, got 'soon'." \
   "$(invalid --slow-after=soon)"

# HISTORY_LIMIT has no "0 disables" reading, so its message carries a second
# line pointing at the switch that does turn history off. Both lines matter:
# without the first the refusal has no rule in it, without the second the user
# is left with no way to express what they asked for.
is "invalid: ct_is_history_limit states the rule" \
   "--history-limit must be a whole number of 1 or more, got '0'." \
   "$(invalid --history-limit=0 | sed -n 1p)"
is "invalid: and points at the switch that keeps no history" \
   "To keep no history at all, use --history=off." \
   "$(invalid --history-limit=0 | sed -n 2p)"

# A non-numeric limit fails the same validator, so it must get the same arm.
# ct_is_history_limit calls ct_is_seconds first, and borrowing that validator's
# message here would tell the user any whole number will do -- including the 0
# the row above refuses.
out="$(invalid --history-limit=abc)"
contains "invalid: a non-numeric limit takes the history-limit arm" "1 or more" "$out"
lacks    "invalid: not the seconds arm" "whole number of seconds" "$out"

# The whole colour list, deliberately: ct_is_valid_color is the only other
# place the accepted names are written down, and a colour added there but not
# here is a value the flag takes while the refusal says it does not exist.
is "invalid: ct_is_valid_color lists every colour it accepts" \
   "Unknown color 'banana'. Pick: none dim gray red green yellow blue magenta cyan." \
   "$(invalid --color=banana)"

# A part colour accepts one word the plain colours do not, and the message is
# the only place the user is told so.
is "invalid: ct_is_valid_part_color also offers the inherit sentinel" \
   "Unknown colour 'banana'. Pick: none dim gray red green yellow blue magenta cyan, or 'inherit' to follow --color." \
   "$(invalid --time-color=banana)"

is "invalid: ct_is_valid_format names the presets and the % rule" \
   "--display must be 24h, short, 12h, iso, or a strftime string containing %, got 'nonsense'." \
   "$(invalid --display=nonsense)"

# The marker message is three lines because a template has three ways to be
# wrong: an unknown part, a group holding none of them, and unbalanced braces.
out="$(invalid --marker='%elapsd')"
contains "invalid: ct_is_valid_marker says the template is unusable" \
         "That marker template is not usable." "$out"
contains "invalid: and names the four parts" \
         "%time, %elapsed, %tool and %date" "$out"
contains "invalid: and mentions the braces balancing" \
         "braces must balance" "$out"

# Two different timezone failures with two different messages. A name of the
# wrong shape never reaches the zoneinfo lookup, so it gets the arm here...
out="$(invalid --tz=..)"
is "invalid: ct_is_valid_tz asks for an IANA name" \
   "Timezone must be an IANA name like Europe/Amsterdam." "$out"
lacks "invalid: and does not claim the zone is unknown" "Unknown timezone" "$out"

# ...while a well-shaped name this machine has never heard of gets valid_tz's
# own message, which quotes the zone back. Needs a timezone database to reach:
# without one valid_tz refuses earlier, with different advice again.
if ct_tz_supported && [ -d /usr/share/zoneinfo ]; then
  contains "invalid: an unknown zone is a different message that quotes it" \
           "Unknown timezone 'Mars/Olympus'." "$(invalid --tz=Mars/Olympus)"
else
  skip "invalid: an unknown zone is a different message that quotes it" \
       "no timezone database, so the zoneinfo lookup is not reached"
fi

is "invalid: a refusal writes nothing to stdout" "" \
   "$(CLAUDE_TIMESTAMP_CONFIG="$WORK/invalid.conf" \
      bash "$SCRIPTS/setup.sh" --color=banana 2>/dev/null)"

# The wizard passes the config key rather than a flag, and the message follows
# the label it is given. A user who answered a question was never offered a
# --slow-after to correct, so naming one would send them looking for a flag
# they did not type.
fresh
wiz="$(printf 'on\nlocal\n24h\non\nsoon\n30\nlater\n600\noff\noff\nnone\n\nfalse\nn\n' \
        | bash "$SCRIPTS/setup.sh" 2>&1 >/dev/null)"
contains "invalid: the wizard labels a bad slow-after with the key" \
         "SLOW_AFTER must be a whole number of seconds, got 'soon'." "$wiz"
contains "invalid: the wizard labels a bad idle-after with the key" \
         "IDLE_AFTER must be a whole number of seconds, got 'later'." "$wiz"
lacks "invalid: and never names a flag the wizard user did not type" \
      "--slow-after" "$wiz"

# Two claims no flag and no wizard answer can reach.
#
# The default arm is unreachable through a flag because every row in
# CT_FLAG_TABLE names a validator that has an arm of its own -- it exists for
# the row added tomorrow with one that does not, and silence there would be a
# refusal with no reason attached.
#
# An empty offending value is unreachable the same way: a flag given as `--x=`
# is resolved by the table's empty policy before any validator sees it, and a
# blank wizard answer takes the offered default. So both are called directly.
# setup.sh runs main on its last line and main returns normally once a flag has
# been written, which is what leaves its functions defined after a source.
# shellcheck disable=SC2069  # stderr to the capture, stdout discarded, as above
say_invalid_direct() {
  CLAUDE_TIMESTAMP_CONFIG="$WORK/say-direct.conf" \
    bash -c 'source "$1/setup.sh" --color=cyan >/dev/null 2>&1
             shift
             _ct_say_invalid "$@"' _ "$SCRIPTS" "$@" 2>&1 >/dev/null
}

is "invalid: an unrecognised validator still produces a sentence" \
   "--newflag does not accept 'val'." \
   "$(say_invalid_direct ct_is_something_new --newflag val)"
is "invalid: an empty offending value is still quoted" \
   "SLOW_AFTER must be a whole number of seconds, got ''." \
   "$(say_invalid_direct ct_is_seconds SLOW_AFTER '')"

echo
echo "tool timing"

fresh
is "tool timing is off by default" "off" "$(ct_load_config; printf '%s' "$CT_TOOL_TIMING")"

# The gate every tool call opens with. It is asserted here rather than through
# the hook because the hook's output is identical either way -- what the gate
# decides is whether the call pays for a jq parse, and cost is not something an
# end-to-end assertion can see.
#
# A sentinel is re-staged by every prompt and cleared at session end, so one
# that has not been touched for a day belongs to a session that ended without a
# SessionEnd: a crash, a killed terminal, a machine that slept. Nothing else
# clears it and the prune does not come back for a week, so leaving it counted
# makes one dead session tax every tool call in every other session on the
# machine for seven days.
ct_clear_state "gate-live"; ct_clear_state "gate-dead"
rm -rf "$(ct_state_dir)"; ct_state_ready
refutes "timing gate: an empty state directory wants nothing" ct_timing_wanted

ct_stage_flag "gate-live" "timing-on" "1"
asserts "timing gate: a fresh sentinel is counted" ct_timing_wanted

rm -f "$(ct_state_file gate-live).timing-on"
ct_stage_flag "gate-dead" "timing-on" "1"
touch -t "$(date -d '2 days ago' +%Y%m%d%H%M 2>/dev/null || date -v-2d +%Y%m%d%H%M)" \
  "$(ct_state_file gate-dead).timing-on"
refutes "timing gate: a sentinel from a dead session is not" ct_timing_wanted

# ...and one live session still turns it on for everyone, which is the
# conservative behaviour the gate is built around.
ct_stage_flag "gate-live" "timing-on" "1"
asserts "timing gate: one live session still counts for all" ct_timing_wanted
ct_clear_state "gate-live"; ct_clear_state "gate-dead"

if command -v jq >/dev/null 2>&1; then
  # Disabled: the hook must write nothing at all.
  fresh 'TOOL_TIMING=off'
  printf '{"session_id":"tools","tool_use_id":"t1","tool_name":"Bash","duration_ms":1000}' \
    | bash "$SCRIPTS/post-tool-use.sh"
  if [ -e "$(ct_tool_log tools)" ]; then
    fail "TOOL_TIMING=off records nothing" "no log" "log created"
  else
    pass "TOOL_TIMING=off records nothing"
  fi

  fresh 'TOOL_TIMING=on'
  # post-tool-use.sh now gates on a per-session sentinel that user-prompt-submit.sh
  # normally stages; these cases call the tool hook directly, so the sentinel is
  # staged by hand to stand in for the prompt hook that would otherwise have run.
  ct_stage_flag "tools" "timing-on" "1"

  # Three calls, one of them a different tool. No pairing state is involved any
  # more, so a call is logged on its own rather than needing a start to match.
  printf '{"session_id":"tools","tool_use_id":"t1","tool_name":"Bash","duration_ms":40000}' \
    | bash "$SCRIPTS/post-tool-use.sh"
  printf '{"session_id":"tools","tool_use_id":"t2","tool_name":"Bash","duration_ms":1200}' \
    | bash "$SCRIPTS/post-tool-use.sh"
  printf '{"session_id":"tools","tool_use_id":"t3","tool_name":"Read","duration_ms":400}' \
    | bash "$SCRIPTS/post-tool-use.sh"

  log="$(ct_tool_log tools)"
  is "every completed call is logged" "3" "$(wc -l < "$log" | tr -d ' ')"
  is "the log records tool names" "2" "$(grep -c '^Bash ' "$log")"
  is "milliseconds are converted to seconds" "Bash 40.000 ok" "$(sed -n 1p "$log")"
  is "a sub-second call keeps its precision" "Read 0.400 ok" "$(sed -n 3p "$log")"

  # The per-turn log gets the same line, because the marker reads that one.
  is "the per-turn log gets the same lines" "3" "$(wc -l < "$(ct_turn_tool_log tools)" | tr -d ' ')"

  # No pairing state means no per-call files to leave behind.
  if ls "$(ct_state_dir)"/tools.tool.* >/dev/null 2>&1; then
    fail "no per-call state is created" "no .tool. files" "files created"
  else
    pass "no per-call state is created"
  fi

  # An older harness sends no duration. Logging a zero would drag every average
  # down and could name a tool that took no time as the reason a turn was slow.
  printf '{"session_id":"tools","tool_use_id":"t4","tool_name":"Bash"}' \
    | bash "$SCRIPTS/post-tool-use.sh"
  is "a call with no duration is not logged" "3" "$(wc -l < "$log" | tr -d ' ')"

  printf '{"session_id":"tools","tool_use_id":"t5","tool_name":"Bash","duration_ms":"soon"}' \
    | bash "$SCRIPTS/post-tool-use.sh"
  is "a duration that is not a number is not logged" "3" "$(wc -l < "$log" | tr -d ' ')"

  # A duration_ms string with a leading zero must be read as decimal, not as
  # octal by the shell arithmetic that divides it into seconds. The exit
  # status is asserted explicitly: an unhandled leading zero used to abort
  # the hook non-zero, breaking the branch-wide "every hook exits 0" rule.
  printf '{"session_id":"tools","tool_use_id":"t7","tool_name":"Bash","duration_ms":"0123"}' \
    | bash "$SCRIPTS/post-tool-use.sh"
  status=$?
  is "a leading-zero duration still exits 0" "0" "$status"
  is "a leading-zero duration is read as decimal, not truncated as octal" \
    "Bash 0.123 ok" "$(sed -n 4p "$log")"

  # "0800" is not valid octal (8 is not an octal digit), which is exactly the
  # value that used to abort the hook with an unbound-variable error.
  printf '{"session_id":"tools","tool_use_id":"t8","tool_name":"Bash","duration_ms":"0800"}' \
    | bash "$SCRIPTS/post-tool-use.sh"
  status=$?
  is "a leading-zero duration with an invalid-octal digit still exits 0" "0" "$status"
  is "0800 is logged as 0.800 seconds, not misread as octal" \
    "Bash 0.800 ok" "$(sed -n 5p "$log")"

  # A tool name that could steer a write is reduced before it reaches the log.
  printf '{"session_id":"tools","tool_use_id":"t6","tool_name":"../evil","duration_ms":500}' \
    | bash "$SCRIPTS/post-tool-use.sh"
  is "an unusable tool name is recorded as unknown" "1" "$(grep -c '^unknown ' "$log")"

  # The outcome rides on the log line rather than in a counter, because tool
  # calls run in parallel and a shared read-modify-write loses writes.
  fresh 'TOOL_TIMING=on'
  ct_stage_flag "outcome" "timing-on" "1"
  printf '{"session_id":"outcome","tool_use_id":"t1","tool_name":"Bash","duration_ms":1000,"hook_event_name":"PostToolUse"}' \
    | bash "$SCRIPTS/post-tool-use.sh"
  printf '{"session_id":"outcome","tool_use_id":"t2","tool_name":"Bash","duration_ms":2000,"hook_event_name":"PostToolUseFailure"}' \
    | bash "$SCRIPTS/post-tool-use.sh"
  olog="$(ct_tool_log outcome)"
  is "a successful call is logged as ok" "Bash 1.000 ok" "$(sed -n 1p "$olog")"
  is "a failed call is logged as fail" "Bash 2.000 fail" "$(sed -n 2p "$olog")"
  is "the per-turn log carries the outcome too" "Bash 2.000 fail" "$(sed -n 2p "$(ct_turn_tool_log outcome)")"
  if [ -e "$(ct_state_file outcome).failed" ]; then
    fail "no failure counter is written" "no .failed file" "file created"
  else
    pass "no failure counter is written"
  fi

  # An event name the payload does not carry is not a failure.
  printf '{"session_id":"outcome","tool_use_id":"t3","tool_name":"Read","duration_ms":100}' \
    | bash "$SCRIPTS/post-tool-use.sh"
  is "a call with no event name is logged as ok" "Read 0.100 ok" "$(sed -n 3p "$olog")"

  # The summary counts failures by reading the log, so concurrent appends are
  # all seen rather than racing on one counter.
  fresh 'TOOL_TIMING=on'
  fbase="$(ct_state_file "failcount")"
  mkdir -p "$(ct_state_dir)"
  printf '%s' "$(( $(date +%s) - 600 ))" > "$fbase.start"
  printf '2' > "$fbase.turns"; printf '30' > "$fbase.wait"
  printf 'Bash 40.0 ok\nBash 1.2 fail\nWebFetch 8.1 fail\nRead 0.4 ok\n' > "$fbase.tools"
  out="$(printf '{"session_id":"failcount"}' | bash "$SCRIPTS/session-end.sh" | jq -r '.systemMessage')"
  contains "the summary counts failures from the log" "2 failed" "$out"
  contains "the summary still sums per tool" "Bash 41.2s (2 calls)" "$out"

  # Aggregation in the summary, unchanged: it reads the same two fields.
  base="$(ct_state_file "tools")"
  printf '%s' "$(( $(date +%s) - 600 ))" > "$base.start"
  printf '2' > "$base.turns"; printf '30' > "$base.wait"
  printf 'Bash 40.0\nBash 1.2\nWebFetch 8.1\nRead 0.4\n' > "$log"
  out="$(printf '{"session_id":"tools"}' | bash "$SCRIPTS/session-end.sh" | jq -r '.systemMessage')"
  contains "the summary names the slowest tool first" "slowest tools: Bash 41.2s (2 calls)" "$out"
  contains "the summary counts a single call in the singular" "WebFetch 8.1s (1 call)" "$out"
  contains "the summary keeps the turn line too" "over 2 turns" "$out"

  fresh 'TOOL_TIMING=off'
  printf '%s' "$(( $(date +%s) - 600 ))" > "$base.start"
  printf '2' > "$base.turns"; printf '30' > "$base.wait"
  printf 'Bash 40.0\n' > "$log"
  out="$(printf '{"session_id":"tools"}' | bash "$SCRIPTS/session-end.sh" | jq -r '.systemMessage')"
  lacks "TOOL_TIMING=off omits the tool line" "slowest tools" "$out"
fi

echo
echo "marker templates"

# The renderer is a pure function of its arguments: template, then the four
# parts already painted. An absent part is the empty string.
m() { ct_render_marker "$1" "$2" "$3" "$4" "$5"; printf '%s' "$CT_MARKER"; }

DEFTPL='[{%date }%time{ %elapsed}{ · %tool}]'

is "marker: everything present" "[Aug 21 13:22:13 +2m14s · Bash 1m58s]" \
  "$(m "$DEFTPL" 13:22:13 +2m14s 'Bash 1m58s' 'Aug 21')"
is "marker: no date, no tool"   "[13:22:13 +2m14s]" \
  "$(m "$DEFTPL" 13:22:13 +2m14s '' '')"
is "marker: clock only"         "[13:22:13]" \
  "$(m "$DEFTPL" 13:22:13 '' '' '')"
is "marker: date but nothing else" "[Aug 21 13:22:13]" \
  "$(m "$DEFTPL" 13:22:13 '' '' 'Aug 21')"

# A group carries its own decoration, which is the whole reason groups exist.
is "marker: group keeps its decoration" "13:22:13 (+2m14s)" \
  "$(m '%time{ (%elapsed)}' 13:22:13 +2m14s '' '')"
is "marker: group vanishes whole"       "13:22:13" \
  "$(m '%time{ (%elapsed)}' 13:22:13 '' '' '')"

# A group with two placeholders is kept when only some are empty.
is "marker: partly filled group is kept" "13:22:13 · Bash 1m58s" \
  "$(m '%time{ %elapsed · %tool}' 13:22:13 '' 'Bash 1m58s' '')"

# Outside a group an empty part eats one run of spaces, on either side.
is "marker: empty part eats the space before it" "[13:22:13]" \
  "$(m '[%time %elapsed]' 13:22:13 '' '' '')"
is "marker: empty part eats the space after it"  "[13:22:13]" \
  "$(m '[%elapsed %time]' 13:22:13 '' '' '')"
is "marker: only one run is eaten"               "13:22:13" \
  "$(m '%time  %elapsed' 13:22:13 '' '' '')"
is "marker: a filled part eats nothing"          "[13:22:13 +2m14s]" \
  "$(m '[%time %elapsed]' 13:22:13 +2m14s '' '')"

# Braces with no placeholder inside are literal, so no escaping is needed.
is "marker: braces without a placeholder are literal" "{literal}13:22:13" \
  "$(m '{literal}%time' 13:22:13 '' '' '')"

# A bare percent needs no escaping either.
is "marker: a bare percent is literal" "13:22:13 100%" \
  "$(m '%time 100%' 13:22:13 '' '' '')"

# Substituted text is never re-scanned. DISPLAY_FORMAT accepts a raw strftime
# string, so a rendered value really can contain a percent sign, and a
# replace-in-place renderer would substitute it a second time.
is "marker: a substituted value is not re-scanned" "[%tool]" \
  "$(m '[%time]' '%tool' '' 'Bash 1m58s' '')"

# Non-ASCII passes through untouched.
is "marker: unicode literals survive" "⟨13:22:13⟩" \
  "$(m '⟨%time⟩' 13:22:13 '' '' '')"

# A template with no placeholder at all is just literal text.
is "marker: a template with no parts is literal" "hello" \
  "$(m 'hello' 13:22:13 +2m14s '' '')"

# Validation.
asserts "valid: the default template"   ct_is_valid_marker "$DEFTPL"
asserts "valid: a bare percent"         ct_is_valid_marker '%time 100%'
asserts "valid: a trailing percent"     ct_is_valid_marker '%time %'
refutes "invalid: nested groups"        ct_is_valid_marker '%time{ {%elapsed}}'

# Nesting is rejected rather than rendered: _ct_span assumes a span holds no
# braces, so a nested group's inner braces would leak as literal text and the
# inner group would never get the chance to vanish. The validator guarantees
# none of these three ever reaches the renderer.
refutes "invalid: doubled nested group"        ct_is_valid_marker '{{%time}}'
refutes "invalid: two groups, one nested"      ct_is_valid_marker '%time{ (%elapsed){ · %tool}}'
refutes "invalid: nested group after a placeholder" ct_is_valid_marker '{%tool{ (%elapsed)}}'
asserts "valid: no placeholders at all" ct_is_valid_marker 'hello'
refutes "invalid: unknown placeholder"  ct_is_valid_marker '%elapsd'
refutes "invalid: a placeholder with a suffix" ct_is_valid_marker '%timex'
refutes "invalid: unbalanced open brace"  ct_is_valid_marker '[%time{ %elapsed]'
refutes "invalid: unbalanced close brace" ct_is_valid_marker '[%time} %elapsed]'

# A group exists to disappear when the parts inside it are empty, which is the
# only rule the README, the schema and /timestamps state about it. A group
# holding no part at all cannot do that: the renderer has nothing to test, so
# it falls through and emits the braces themselves, and the user reads literal
# {hi} on every message for the rest of the session. Refused at the validator,
# where a wrong template already produces a message they can act on.
refutes "invalid: a group with no placeholder" ct_is_valid_marker '[{hi}%time]'
refutes "invalid: an empty group"              ct_is_valid_marker '%time{}'
asserts "valid: a group whose part is decorated" ct_is_valid_marker '%time{ (%elapsed)}'
# Text outside a group has never needed one, and must not start needing one.
asserts "valid: literal braces are only a group when they hold a part" ct_is_valid_marker 'hello'

# write_config interpolates a value into KEY=value with no escaping, so a
# newline in a marker or format flag writes a second config line that the
# parser reads back as a real setting -- and because it lands after the key
# it came from, it wins. --marker=$'x\nENABLED=off' reproduced this: setup.sh
# reported success and silently disabled the whole plugin. Rejecting a
# control character here closes the flag path and any other path a value
# could reach the config file through.
refutes "marker: a newline is rejected"  ct_is_valid_marker "$(printf 'x\nENABLED=off')"
refutes "marker: a carriage return too"  ct_is_valid_marker "$(printf 'x\ry')"
refutes "format: a newline is rejected"  ct_is_valid_format "$(printf '%%H\nENABLED=off')"
asserts "marker: ordinary text still passes" ct_is_valid_marker '[{%date }%time{ %elapsed}]'
asserts "format: a strftime string still passes" ct_is_valid_format '%H:%M'

# The suite itself runs under set -uo pipefail with no -e, and every marker
# assertion above sits inside $(m ...), which suppresses -e for the callee's
# whole dynamic extent -- so nothing above can see a bare non-zero return from
# an internal helper abort the caller. Every hook in this repo starts with
# set -euo pipefail, so this is the shape that actually runs in production.
marker_survives_set_e() {
  local tpl="$1" want="$2"
  bash -c '
      set -euo pipefail
      . "$1/hooks/scripts/lib/config.sh"
      ct_render_marker "$2" T E O D
      [ "$CT_MARKER" = "$3" ]
    ' _ "$ROOT" "$tpl" "$want" >/dev/null 2>&1
}
for row in "100%|100%" "%time 100%|T 100%" "%|%" "%elapsd|%elapsd" "%timex|%timex"; do
  tpl="${row%%|*}"; want="${row#*|}"
  if marker_survives_set_e "$tpl" "$want"; then
    pass "marker: renders under set -e without aborting [$tpl]"
  else
    fail "marker: renders under set -e without aborting [$tpl]" "an exit 0" "aborted or wrong output"
  fi
done

# Neither function may print, since message-display.sh writes JSON to stdout
# and a helper that printed -- to either stream -- would corrupt the hook's
# output or its diagnostics. Checked against a malformed template, the case
# most likely to tempt an errant echo.
errfile="$WORK/marker-print-probe.$$"
out="$(ct_render_marker '{%time' T E O D 2>"$errfile")"
err="$(cat "$errfile" 2>/dev/null)"; rm -f "$errfile"
is "marker: render prints nothing to stdout" "" "$out"
is "marker: render prints nothing to stderr" "" "$err"

out2="$(ct_is_valid_marker '{%time' 2>"$errfile")"
err2="$(cat "$errfile" 2>/dev/null)"; rm -f "$errfile"
is "marker: validate prints nothing to stdout" "" "$out2"
is "marker: validate prints nothing to stderr" "" "$err2"

# Every template below is rendered and validated under a timeout, so a missing
# index increment fails the suite instead of hanging it. The inputs are the
# shapes most likely to trip a hand-written scanner: empty, a lone delimiter,
# unterminated constructs, and deep nesting.
if command -v timeout >/dev/null 2>&1; then
  for tpl in '' '%' '{' '}' '{}' '%%' '{{{{' '}}}}' '%time%time' '{%time' \
             '%{time}' '{ }' '%z' '%timetime' '[%time' '{%time{%elapsed{%tool}}}' ; do
    # shellcheck disable=SC2016  # $1 and $2 belong to the inner shell, by design
    if timeout 5 bash -c '
        . "$1/hooks/scripts/lib/config.sh"
        ct_is_valid_marker "$2" || true
        ct_render_marker "$2" T E O D || true
      ' _ "$ROOT" "$tpl" >/dev/null 2>&1; then
      pass "marker: terminates on [$tpl]"
    else
      fail "marker: terminates on [$tpl]" "an exit" "timed out or crashed"
    fi
  done
else
  echo "  skip timeout not installed, termination cases not run"
fi

# Random templates over the alphabet that matters. The seed is fixed so a
# failure is reproducible; this is a property check, not a lottery.
if command -v timeout >/dev/null 2>&1; then
  RANDOM=20260821
  fuzz_bad=0; fuzz_n=0
  while [ "$fuzz_n" -lt 200 ]; do
    fuzz_n=$(( fuzz_n + 1 ))
    tpl=""; len=$(( RANDOM % 12 + 1 ))
    while [ "${#tpl}" -lt "$len" ]; do
      case $(( RANDOM % 10 )) in
        0) tpl="$tpl%" ;;     1) tpl="$tpl{" ;;      2) tpl="$tpl}" ;;
        3) tpl="$tpl%time" ;; 4) tpl="$tpl%elapsed";; 5) tpl="$tpl " ;;
        6) tpl="${tpl}[" ;;   7) tpl="$tpl]" ;;      8) tpl="$tpl%tool" ;;
        *) tpl="${tpl}x" ;;
      esac
    done
    if ct_is_valid_marker "$tpl"; then
      # Accepted, so the renderer must handle it: terminate, and leave no
      # placeholder text behind, since every part was given a value.
      # shellcheck disable=SC2016  # $1 and $2 belong to the inner shell, by design
      if ! timeout 5 bash -c '
            . "$1/hooks/scripts/lib/config.sh"
            ct_render_marker "$2" T E O D
            case "$CT_MARKER" in *%time*|*%elapsed*|*%tool*|*%date*) exit 1 ;; esac
          ' _ "$ROOT" "$tpl" >/dev/null 2>&1; then
        fuzz_bad=$(( fuzz_bad + 1 ))
        printf '         accepted but not rendered: [%s]\n' "$tpl"
      fi
    fi
  done
  is "marker: every accepted template renders" "0" "$fuzz_bad"
else
  echo "  skip timeout not installed, fuzz not run"
fi

# Every named look in schema.json must render to the string stored beside it.
#
# /timestamps may not run anything, so it shows these stored strings as
# previews. Without this test they would be prose that drifts; with it they are
# strings CI has proven the renderer produces, which is what keeps the promise
# that a preview cannot differ from what you will actually see.
if command -v jq >/dev/null 2>&1; then
  pv_time="$(jq -r '.preview_context.time' "$ROOT/schema.json")"
  pv_elapsed="$(jq -r '.preview_context.elapsed' "$ROOT/schema.json")"
  pv_tool="$(jq -r '.preview_context.tool' "$ROOT/schema.json")"
  pv_date="$(jq -r '.preview_context.date' "$ROOT/schema.json")"

  marker_names="$(jq -r '.markers | keys[]' "$ROOT/schema.json")"
  is "markers: the block is not empty" "0" "$([ -n "$marker_names" ] && echo 0 || echo 1)"

  while read -r name; do
    [ -n "$name" ] || continue
    tpl="$(jq -r --arg n "$name" '.markers[$n].set' "$ROOT/schema.json")"
    want="$(jq -r --arg n "$name" '.markers[$n].renders' "$ROOT/schema.json")"
    asserts "markers: $name is a valid template" ct_is_valid_marker "$tpl"
    ct_render_marker "$tpl" "$pv_time" "$pv_elapsed" "$pv_tool" "$pv_date"
    is "markers: $name renders what schema.json claims" "$want" "$CT_MARKER"
  done <<EOF
$marker_names
EOF

  # ct_is_valid_color accepts "off" and "grey" as aliases for "none" and
  # "gray", and schema.json listed neither. commands/timestamps.md calls the
  # schema the only source of truth about what a key may hold and tells the
  # model to refuse a value it does not accept -- so a user asking for grey
  # was told grey is not a colour, by a contract narrower than the code behind
  # it. check-docs.sh could not catch it: it asserts every listed value passes
  # its validator, never that every accepted value is listed.
  #
  # They live in `aliases` rather than in `values` because `values` is also the
  # list the picker offers, and a picker showing both gray and grey is worse
  # than one showing either.
  for schema_key in COLOR SLOW_COLOR TIME_COLOR ELAPSED_COLOR TOOL_COLOR; do
    for schema_alias in off grey; do
      is "schema: $schema_key accepts the alias '$schema_alias'" "1" \
        "$(jq -r --arg k "$schema_key" --arg a "$schema_alias" \
             '[(.keys[$k].values // [])[], (.keys[$k].aliases // [])[]]
              | if index($a) then 1 else 0 end' "$ROOT/schema.json")"
    done
  done
fi

echo
echo "marker rendering end to end"

# The regression that matters: a default configuration must render exactly what
# the hand-assembled marker rendered, escape sequences included. Anything else
# changes what every existing user sees on upgrade, for a feature they did not
# ask for.
#
# Asserted through ct_render_marker with the same parts and colours
# message-display.sh passes it, rather than through the hook, so the assertion
# is about the rendering rather than about the clock.
fresh 'COLOR=dim' 'SLOW_COLOR=yellow'
ct_paint_part "$CT_TIME_COLOR"    "13:22:13"     "$CT_COLOR"; p_time="$_CT_PART"
ct_paint_part "$CT_SLOW_COLOR"    "+3m20s"       "$CT_COLOR"; p_slow="$_CT_PART"
ct_paint_part "$CT_TOOL_COLOR"    "Bash 3m10s"   "$CT_COLOR"; p_tool="$_CT_PART"
ct_render_marker "$CT_MARKER_TEMPLATE" "$p_time" "$p_slow" "$p_tool" ""
ct_color_seq "$CT_COLOR"; base="$_CT_SEQ"
is "marker: a default config renders exactly what it used to" \
  "${base}[13:22:13 $(printf '\033[33m')+3m20s$(printf '\033[0m')${base} · Bash 3m10s]$(printf '\033[0m')" \
  "${base}${CT_MARKER}$(printf '\033[0m')"

# Per-part colour, which is the feature.
fresh 'COLOR=dim' 'TIME_COLOR=gray' 'ELAPSED_COLOR=cyan'
ct_paint_part "$CT_TIME_COLOR"    "13:22:13" "$CT_COLOR"; p_time="$_CT_PART"
ct_paint_part "$CT_ELAPSED_COLOR" "+2m14s"   "$CT_COLOR"; p_el="$_CT_PART"
ct_render_marker "$CT_MARKER_TEMPLATE" "$p_time" "$p_el" "" ""
contains "marker: time takes its own colour"     "$(printf '\033[90m')13:22:13" "$CT_MARKER"
contains "marker: duration takes its own colour" "$(printf '\033[36m')+2m14s"   "$CT_MARKER"

# A custom template reaches the screen.
fresh 'COLOR=none' 'MARKER=%time' 'ELAPSED=off' 'IDLE_AFTER=0' 'DATE_ROLLOVER=off' 'TZ=UTC' 'DISPLAY_FORMAT=short'
before="$(TZ=UTC date '+%H:%M') x"
out="$(printf '{"session_id":"tpl","index":0,"delta":"x"}' \
  | bash "$SCRIPTS/message-display.sh" | jq -r '.hookSpecificOutput.displayContent')"
after="$(TZ=UTC date '+%H:%M') x"
if [ "$out" = "$before" ] || [ "$out" = "$after" ]; then
  pass "marker: a bracketless template reaches the screen"
else
  fail "marker: a bracketless template reaches the screen" "$before" "$out"
fi

# An empty part leaves no trace through the hook, not merely in the renderer.
fresh 'COLOR=none' 'MARKER=[%time %elapsed]' 'ELAPSED=off' 'IDLE_AFTER=0' 'DATE_ROLLOVER=off' 'TZ=UTC' 'DISPLAY_FORMAT=short'
out="$(printf '{"session_id":"tpl2","index":0,"delta":"x"}' \
  | bash "$SCRIPTS/message-display.sh" | jq -r '.hookSpecificOutput.displayContent')"
lacks "marker: an absent duration leaves no gap" "  " "$out"
lacks "marker: and no dangling space before the bracket" " ]" "$out"

echo
echo "state pruning"

fresh
mkdir -p "$(ct_state_dir)"
# A fixed date in the past rather than a relative one: GNU touch spells that
# -d '10 days ago' and BSD touch spells it -v-10d, but -t works on both.
touch -t 202001010000 "$(ct_state_dir)/ancient"
: > "$(ct_state_dir)/recent"
ct_prune_state
if [ -e "$(ct_state_dir)/ancient" ]; then
  fail "pruning removes stale session state" "ancient file gone" "still there"
else
  pass "pruning removes stale session state"
fi
asserts "pruning keeps current session state" test -e "$(ct_state_dir)/recent"

# .start was the one state file written once and never touched again, so a
# session left open longer than the prune window lost it while still running.
# _CT_START then reads 0 and session-end skips both the summary and the history
# row: the longest session on the machine is the one that goes unrecorded.
# Every other counter is rewritten on each prompt, so only this one aged out.
ct_clear_state "longrun"
lbase="$(ct_state_file longrun)"
longstart="$(( $(date +%s) - 700000 ))"
ct_turn_open "longrun" "$longstart"
touch -t 202001010000 "$lbase.start"
ct_turn_open "longrun" "$(date +%s)"
ct_prune_state
asserts "a session running past the prune window keeps its start" test -r "$lbase.start"
is "and the start time it keeps is the original one" "$longstart" "$(ct_read_counter "$lbase.start")"
ct_clear_state "longrun"

rm -rf "$(ct_state_dir)"
ct_prune_state
pass "pruning a missing state directory is not an error"

echo
echo "awkward input"

if command -v jq >/dev/null 2>&1; then
  fresh 'COLOR=none' 'ELAPSED=off' 'IDLE_AFTER=0' 'DATE_ROLLOVER=off'

  # Message text is attacker-adjacent in the sense that it is arbitrary: it can
  # carry quotes, backslashes and escape sequences, and the hook rebuilds it
  # into JSON. jq builds the payload here so the test cannot pass by accident
  # through its own quoting.
  # shellcheck disable=SC2016  # the literal $(...) and backticks are the point
  awkward='he said "hi" \ then \n did $(nothing) `also nothing`'
  payload="$(jq -nc --arg d "$awkward" '{session_id:"awkward",index:0,delta:$d}')"
  out="$(printf '%s' "$payload" | bash "$SCRIPTS/message-display.sh" | jq -r '.hookSpecificOutput.displayContent')"
  contains "quotes and backslashes survive intact" "$awkward" "$out"

  esc="$(printf 'text with \033[31m an escape')"
  payload="$(jq -nc --arg d "$esc" '{session_id:"awkward",index:0,delta:$d}')"
  out="$(printf '%s' "$payload" | bash "$SCRIPTS/message-display.sh" | jq -r '.hookSpecificOutput.displayContent')"
  contains "escape sequences in the message are left alone" "$esc" "$out"

  payload="$(jq -nc '{session_id:"awkward",index:0,delta:""}')"
  out="$(printf '%s' "$payload" | bash "$SCRIPTS/message-display.sh" | jq -r '.hookSpecificOutput.displayContent')"
  case "$out" in "["*) pass "an empty message still gets a marker" ;; *) fail "an empty message still gets a marker" "a marker" "$out" ;; esac

  # A payload missing the fields the hook reads must not crash it.
  out="$(printf '{}' | bash "$SCRIPTS/message-display.sh" 2>/dev/null || echo CRASHED)"
  case "$out" in *CRASHED*) fail "a payload with no fields is survivable" "no crash" "$out" ;; *) pass "a payload with no fields is survivable" ;; esac

  fresh 'COLOR=dim' 'ELAPSED=off' 'IDLE_AFTER=0' 'DATE_ROLLOVER=off'
  out="$(printf '{"session_id":"nc","index":0,"delta":"x"}' | NO_COLOR=1 bash "$SCRIPTS/message-display.sh" | jq -r '.hookSpecificOutput.displayContent')"
  lacks "NO_COLOR reaches the rendered marker" "[2m" "$out"

  echo
  echo "degrading without jq"

  # PATH is emptied rather than jq removed, so this exercises the real branch
  # every hook opens with. bash itself is invoked by the path it is running as.
  out="$(printf '{"session_id":"x"}' | PATH=/nonexistent "$BASH" "$SCRIPTS/session-start.sh" 2>/dev/null || true)"
  contains "session start explains a missing jq" "jq" "$out"
  out="$(printf '{"session_id":"x","index":0,"delta":"hello"}' | PATH=/nonexistent "$BASH" "$SCRIPTS/message-display.sh" 2>/dev/null || true)"
  is "message display stays silent without jq" "" "$out"
  out="$(printf '{"session_id":"x"}' | PATH=/nonexistent "$BASH" "$SCRIPTS/user-prompt-submit.sh" 2>/dev/null || true)"
  is "prompt submit stays silent without jq" "" "$out"

  # Saying it on screen is not enough: the message is easy to miss, and on a
  # client that swallows it there is nothing left to look at. The one branch
  # that cannot use jq to record that jq is missing has to hand-build the file
  # instead, so the absence of a facts file stops meaning two different things.
  #
  # `command` is shadowed for this one subprocess rather than PATH being
  # emptied, because writing the file needs `date`, `mv` and `rm`, and a PATH
  # built to hold those and not jq is not portable: Git Bash has no working
  # symlinks, and a PATH stripped to one directory loses the DLLs its
  # utilities load. Shadowing hides jq alone and leaves the rest of the
  # machine as it is. Emptying PATH, just above, tests the other thing: that
  # the hook survives having nothing at all.
  NO_JQ="$WORK/no-jq.sh"
  cat > "$NO_JQ" <<'EOF'
command() {
  case "$*" in
    "-v jq") return 1 ;;
    *) builtin command "$@" ;;
  esac
}
EOF
  rm -f "$CLAUDE_TIMESTAMP_FACTS"
  printf '{"session_id":"x"}' \
    | BASH_ENV="$NO_JQ" CLAUDE_CODE_ENTRYPOINT=claude-desktop bash "$SCRIPTS/session-start.sh" >/dev/null 2>&1 || true
  asserts "facts: a missing jq is recorded, not merely announced" \
    jq -e '.clients["claude-desktop"].jq == false' "$CLAUDE_TIMESTAMP_FACTS"
  rm -f "$CLAUDE_TIMESTAMP_FACTS"

  # The writer that has jq creates the directory it writes into. The one that
  # does not has to as well, or the fact that jq is missing goes unrecorded on
  # exactly the machine where nothing else can record it either.
  NESTED_FACTS="$WORK/nested-facts/deeper/facts.json"
  rm -rf "$WORK/nested-facts"
  printf '{"session_id":"x"}' \
    | BASH_ENV="$NO_JQ" CLAUDE_TIMESTAMP_FACTS="$NESTED_FACTS" \
      CLAUDE_CODE_ENTRYPOINT=claude-desktop bash "$SCRIPTS/session-start.sh" >/dev/null 2>&1 || true
  asserts "facts: the degraded write creates its own directory" \
    jq -e '.clients["claude-desktop"].jq == false' "$NESTED_FACTS"
  rm -rf "$WORK/nested-facts"
fi

echo
echo "validating the config"

is "a known colour is accepted"     "0" "$(ct_is_valid_color cyan     && echo 0 || echo 1)"
is "an unknown colour is rejected"  "1" "$(ct_is_valid_color banana   && echo 0 || echo 1)"
is "a preset format is accepted"    "0" "$(ct_is_valid_format short   && echo 0 || echo 1)"
is "a strftime format is accepted"  "0" "$(ct_is_valid_format '%H:%M' && echo 0 || echo 1)"
is "a nonsense format is rejected"  "1" "$(ct_is_valid_format wat     && echo 0 || echo 1)"
is "a number is seconds"            "0" "$(ct_is_seconds 30           && echo 0 || echo 1)"
is "a word is not seconds"          "1" "$(ct_is_seconds soon         && echo 0 || echo 1)"
is "an empty timezone is fine"      "0" "$(ct_is_valid_tz ''          && echo 0 || echo 1)"
is "an absolute timezone path is not" "1" "$(ct_is_valid_tz /etc/passwd && echo 0 || echo 1)"
is "a traversing timezone is not"   "1" "$(ct_is_valid_tz a/../b      && echo 0 || echo 1)"
# The three patterns all required a slash BEFORE the traversal, so a name that
# opens with one walked straight past them. The guard reads as exhaustive and
# should be.
refutes "a timezone opening with a traversal is rejected" ct_is_valid_tz '../etc'
refutes "and a bare traversal is too"                     ct_is_valid_tz '..'
asserts "a name that merely starts with dots is still fine" ct_is_valid_tz '..zone/Oslo'

# TZ is a third free-text setting that reaches write_config the same way
# MARKER and the formats do, so it needs the same control-character guard
# rather than relying on setup.sh's zoneinfo-existence check, which is
# skipped (and so provides no protection at all) when $ZONEINFO is not a
# directory.
refutes "a control character in a timezone is rejected" \
  ct_is_valid_tz "$(printf 'Europe/Amsterdam\nENABLED=off')"
asserts "an ordinary timezone name still passes" ct_is_valid_tz 'Europe/Amsterdam'

fresh 'COLOR=cyan' 'SLOW_AFTER=30'
is "a good config reports no problems" "" "$CT_CONFIG_PROBLEMS"

fresh 'SLOW_AFTER=abc' 'COLOR=banana' 'ELAPSED=maybe' 'DISPLAY_FORMAT=wat' 'INJECT_CONTEXT=perhaps'
is "a bad number falls back"   "60"   "$CT_SLOW_AFTER"
is "a bad colour falls back"   "dim"  "$CT_COLOR"
is "a bad toggle falls back"   "on"   "$CT_ELAPSED"
is "a bad format falls back"   "24h"  "$CT_DISPLAY_FORMAT"
is "a bad boolean falls back"  "true" "$CT_INJECT_CONTEXT"
contains "the bad value is named"      "COLOR=banana" "$CT_CONFIG_PROBLEMS"
contains "the replacement is named"    "using dim"    "$CT_CONFIG_PROBLEMS"
is "every bad value is reported" "5" "$(printf '%s\n' "$CT_CONFIG_PROBLEMS" | grep -c 'is not valid')"

if command -v jq >/dev/null 2>&1; then
  # A broken config must still produce a usable marker, drawn with the
  # defaults that replaced the unusable values.
  fresh 'SLOW_AFTER=abc' 'COLOR=banana' 'ELAPSED=off' 'DATE_ROLLOVER=off' 'IDLE_AFTER=oops'
  out="$(printf '{"session_id":"bad","index":0,"delta":"x"}' | bash "$SCRIPTS/message-display.sh" 2>/dev/null | jq -r '.hookSpecificOutput.displayContent' 2>/dev/null)"
  contains "a nonsense config still renders a marker" "] x" "$(strip_ansi "$out")"
  contains "an unusable colour falls back to the default" "[2m" "$out"

  out="$(printf '{"session_id":"x"}' | bash "$SCRIPTS/session-start.sh" | jq -r '.systemMessage')"
  contains "session start names the broken settings" "COLOR=banana" "$out"
  contains "session start points at the fix" "/timestamps" "$out"

  fresh 'COLOR=cyan'
  out="$(printf '{"session_id":"x"}' | bash "$SCRIPTS/session-start.sh")"
  lacks "session start says nothing about a good config" "could not be used" "$out"

  refutes "doctor fails on a broken config" bash -c "
    printf 'COLOR=banana\n' > '$CLAUDE_TIMESTAMP_CONFIG'
    bash '$SCRIPTS/setup.sh' --doctor"
  fresh 'COLOR=cyan'
  asserts "doctor passes on a good config" bash "$SCRIPTS/setup.sh" --doctor
fi

fresh 'MARKER=%elapsd'
is "validate: a bad marker falls back" '[{%date }%time{ %elapsed}{ · %tool}]' "$CT_MARKER_TEMPLATE"
contains "validate: and says so" "MARKER=%elapsd is not valid" "$CT_CONFIG_PROBLEMS"

fresh 'MARKER=[%time{ %elapsed]'
is "validate: an unbalanced brace falls back" '[{%date }%time{ %elapsed}{ · %tool}]' "$CT_MARKER_TEMPLATE"

fresh 'TIME_COLOR=banana'
is "validate: a bad part colour falls back to inherit" "" "$CT_TIME_COLOR"
contains "validate: and names it" "TIME_COLOR=banana is not valid" "$CT_CONFIG_PROBLEMS"

fresh 'TIME_COLOR=none'
is "validate: none is a usable part colour" "none" "$CT_TIME_COLOR"

# --- ct_validate_config, arm by arm -----------------------------------------
#
# The validator is the reason every other file can read a CT_* variable without
# checking it first: whatever the config file said, by the time it returns each
# of the twenty settings holds a usable value and CT_CONFIG_PROBLEMS names the
# ones that had to be replaced. Only seven of its arms had a case of their own,
# so an arm wired to the wrong validator, or reaching for the neighbouring
# row's default, was invisible for most of the file.

# Every setting the file can carry, each set to a legal value that is NOT its
# default. A value left as written proves the arm passed it through; one that
# happens to equal the default would prove nothing.
ct_good_conf=(
  'ENABLED=off'
  'TZ=Asia/Tokyo'
  'DISPLAY_FORMAT=short'
  'CONTEXT_FORMAT=iso'
  'COLOR=cyan'
  'MARKER=%time'
  'TIME_COLOR=green'
  'ELAPSED_COLOR=blue'
  'TOOL_COLOR=magenta'
  'ELAPSED=off'
  'DATE_ROLLOVER=off'
  'SLOW_AFTER=5'
  'SLOW_COLOR=red'
  'IDLE_AFTER=7'
  'SUMMARY=off'
  'SUBAGENTS=off'
  'TOOL_TIMING=on'
  'HISTORY=off'
  'HISTORY_LIMIT=9'
  'INJECT_CONTEXT=false'
)
fresh "${ct_good_conf[@]}"
is "validate: a fully legal config is passed through untouched" \
  "off|Asia/Tokyo|short|iso|cyan|%time|green|blue|magenta|off|off|5|red|7|off|off|on|off|9|false" \
  "$CT_ENABLED|$CT_TZ|$CT_DISPLAY_FORMAT|$CT_CONTEXT_FORMAT|$CT_COLOR|$CT_MARKER_TEMPLATE|$CT_TIME_COLOR|$CT_ELAPSED_COLOR|$CT_TOOL_COLOR|$CT_ELAPSED|$CT_DATE_ROLLOVER|$CT_SLOW_AFTER|$CT_SLOW_COLOR|$CT_IDLE_AFTER|$CT_SUMMARY|$CT_SUBAGENTS|$CT_TOOL_TIMING|$CT_HISTORY|$CT_HISTORY_LIMIT|$CT_INJECT_CONTEXT"
is "validate: and a legal config reports nothing" "" "$CT_CONFIG_PROBLEMS"

# The arms nothing pinned. All wrong at once rather than one file each, so an
# arm that borrowed the row above it shows up as a wrong value here instead of
# passing on its own.
fresh 'CONTEXT_FORMAT=wat' 'SLOW_COLOR=banana' 'IDLE_AFTER=oops' 'DATE_ROLLOVER=maybe' \
      'SUMMARY=maybe' 'SUBAGENTS=maybe' 'TOOL_TIMING=maybe' 'HISTORY=maybe' \
      'ELAPSED_COLOR=banana' 'TOOL_COLOR=banana'
is "validate: a bad CONTEXT_FORMAT falls back" "24h"    "$CT_CONTEXT_FORMAT"
is "validate: a bad SLOW_COLOR falls back"     "yellow" "$CT_SLOW_COLOR"
is "validate: a bad IDLE_AFTER falls back"     "3600"   "$CT_IDLE_AFTER"
is "validate: a bad DATE_ROLLOVER falls back"  "on"     "$CT_DATE_ROLLOVER"
is "validate: a bad SUMMARY falls back"        "on"     "$CT_SUMMARY"
is "validate: a bad SUBAGENTS falls back"      "on"     "$CT_SUBAGENTS"
# The one toggle whose default is off, because it costs two forks per tool
# call. An arm that copied a neighbour's default would switch it on for
# everyone who typoed the value.
is "validate: a bad TOOL_TIMING falls back to off, not on" "off" "$CT_TOOL_TIMING"
is "validate: a bad HISTORY falls back"        "on"     "$CT_HISTORY"
# A part colour has no colour to fall back to -- the empty string is how it
# says "inherit COLOR" -- so these two must not be repaired into a real name.
is "validate: a bad ELAPSED_COLOR falls back to inherit" "" "$CT_ELAPSED_COLOR"
is "validate: a bad TOOL_COLOR falls back to inherit"    "" "$CT_TOOL_COLOR"
contains "validate: and the CONTEXT_FORMAT problem names its own key and default" \
  "CONTEXT_FORMAT=wat is not valid, using 24h" "$CT_CONFIG_PROBLEMS"
contains "validate: and the SLOW_COLOR problem names its own key and default" \
  "SLOW_COLOR=banana is not valid, using yellow" "$CT_CONFIG_PROBLEMS"
contains "validate: and the TOOL_TIMING problem names its own key and default" \
  "TOOL_TIMING=maybe is not valid, using off" "$CT_CONFIG_PROBLEMS"
is "validate: ten unusable settings make ten problems" "10" \
  "$(printf '%s\n' "$CT_CONFIG_PROBLEMS" | grep -c 'is not valid')"

# ct_is_valid_tz is the only thing between a hand-edited file and a zone name
# that walks out of the zoneinfo directory.
fresh 'TZ=../etc'
is "validate: a traversing timezone falls back to local time" "" "$CT_TZ"
contains "validate: and says which value it dropped" \
  "TZ=../etc is not valid" "$CT_CONFIG_PROBLEMS"

# A newline cannot arrive from the file -- the parser reads a line at a time --
# but it can arrive from a caller that assigns CT_TZ itself, which is what the
# setup flag path does before writing the value back out. Left in, the second
# line would be read back as a real setting on the next load.
fresh
CT_TZ="$(printf 'Europe/Amsterdam\nENABLED=off')"
ct_validate_config
is "validate: a timezone carrying a newline falls back to local time" "" "$CT_TZ"
contains "validate: and the smuggled line is reported rather than kept" \
  "TZ=Europe/Amsterdam" "$CT_CONFIG_PROBLEMS"

# Every setting unusable at once. A validator that gave up at the first
# failure, or that filed one setting under another's name, shows up in the
# count and in the per-key tally rather than as a wrong value nobody reads.
ct_bad_conf=(
  'ENABLED=maybe'
  'TZ=/etc/passwd'
  'DISPLAY_FORMAT=wat'
  'CONTEXT_FORMAT=wat'
  'COLOR=banana'
  'MARKER=%elapsd'
  'TIME_COLOR=banana'
  'ELAPSED_COLOR=banana'
  'TOOL_COLOR=banana'
  'ELAPSED=maybe'
  'DATE_ROLLOVER=maybe'
  'SLOW_AFTER=soon'
  'SLOW_COLOR=banana'
  'IDLE_AFTER=later'
  'SUMMARY=maybe'
  'SUBAGENTS=maybe'
  'TOOL_TIMING=maybe'
  'HISTORY=maybe'
  'HISTORY_LIMIT=0'
  'INJECT_CONTEXT=perhaps'
)
fresh "${ct_bad_conf[@]}"
is "validate: twenty unusable settings make twenty problems" "20" \
  "$(printf '%s\n' "$CT_CONFIG_PROBLEMS" | grep -c 'is not valid')"
ct_miscounted=""
for ct_key in ENABLED TZ DISPLAY_FORMAT CONTEXT_FORMAT COLOR MARKER TIME_COLOR \
              ELAPSED_COLOR TOOL_COLOR ELAPSED DATE_ROLLOVER SLOW_AFTER \
              SLOW_COLOR IDLE_AFTER SUMMARY SUBAGENTS TOOL_TIMING HISTORY \
              HISTORY_LIMIT INJECT_CONTEXT; do
  ct_seen="$(printf '%s\n' "$CT_CONFIG_PROBLEMS" | grep -c "^  $ct_key=")"
  [ "$ct_seen" = "1" ] || ct_miscounted="$ct_miscounted $ct_key($ct_seen)"
done
is "validate: each setting reported exactly once, under the key the user typed" \
  "" "$ct_miscounted"
# Replacing them is the point: nothing downstream tests a CT_* variable before
# using it, so all twenty have to be usable on the way out.
is "validate: and every one of them is left holding its own default" \
  "on||24h|24h|dim|[{%date }%time{ %elapsed}{ · %tool}]||||on|on|60|yellow|3600|on|on|off|on|200|true" \
  "$CT_ENABLED|$CT_TZ|$CT_DISPLAY_FORMAT|$CT_CONTEXT_FORMAT|$CT_COLOR|$CT_MARKER_TEMPLATE|$CT_TIME_COLOR|$CT_ELAPSED_COLOR|$CT_TOOL_COLOR|$CT_ELAPSED|$CT_DATE_ROLLOVER|$CT_SLOW_AFTER|$CT_SLOW_COLOR|$CT_IDLE_AFTER|$CT_SUMMARY|$CT_SUBAGENTS|$CT_TOOL_TIMING|$CT_HISTORY|$CT_HISTORY_LIMIT|$CT_INJECT_CONTEXT"

# CT_CONFIG_PROBLEMS is rebuilt on each call rather than appended to. One
# process loads the config more than once -- a hook sourced after session-start
# reloads it, and the project layer makes a second read routine -- and a list
# that accumulated would keep reporting a setting after it was fixed.
ct_problems_first="$CT_CONFIG_PROBLEMS"
contains "validate: (the load before this one really did report problems)" \
  "COLOR=banana" "$ct_problems_first"
fresh 'COLOR=cyan'
is "validate: a good load does not inherit the previous load's problems" \
  "" "$CT_CONFIG_PROBLEMS"

# The same claim from inside a single load: a second pass over values the first
# pass already replaced has nothing left to say.
fresh 'COLOR=banana' 'SLOW_AFTER=soon'
contains "validate: the first pass reports the unusable colour" \
  "COLOR=banana" "$CT_CONFIG_PROBLEMS"
ct_validate_config
is "validate: a second pass over the repaired values reports nothing" \
  "" "$CT_CONFIG_PROBLEMS"
is "validate: and leaves the repairs it already made alone" \
  "dim 60" "$CT_COLOR $CT_SLOW_AFTER"

# An empty value is what a half-deleted line looks like. Five settings read it
# as a real answer -- TZ means machine local time, the three part colours mean
# inherit COLOR, and an empty MARKER is a deliberate "render no prefix", which
# is why setup.sh's flag table gives MARKER the `value` empty policy while the
# part colours get `error`. The other fifteen have no such reading.
fresh 'ENABLED=' 'TZ=' 'DISPLAY_FORMAT=' 'CONTEXT_FORMAT=' 'COLOR=' 'MARKER=' \
      'TIME_COLOR=' 'ELAPSED_COLOR=' 'TOOL_COLOR=' 'ELAPSED=' 'DATE_ROLLOVER=' \
      'SLOW_AFTER=' 'SLOW_COLOR=' 'IDLE_AFTER=' 'SUMMARY=' 'SUBAGENTS=' \
      'TOOL_TIMING=' 'HISTORY=' 'HISTORY_LIMIT=' 'INJECT_CONTEXT='
is "validate: an empty value falls back wherever empty means nothing" \
  "on|24h|24h|dim|on|on|60|yellow|3600|on|on|off|on|200|true" \
  "$CT_ENABLED|$CT_DISPLAY_FORMAT|$CT_CONTEXT_FORMAT|$CT_COLOR|$CT_ELAPSED|$CT_DATE_ROLLOVER|$CT_SLOW_AFTER|$CT_SLOW_COLOR|$CT_IDLE_AFTER|$CT_SUMMARY|$CT_SUBAGENTS|$CT_TOOL_TIMING|$CT_HISTORY|$CT_HISTORY_LIMIT|$CT_INJECT_CONTEXT"
is "validate: and stays empty for the five that read empty as an answer" \
  "" "$CT_TZ$CT_TIME_COLOR$CT_ELAPSED_COLOR$CT_TOOL_COLOR$CT_MARKER_TEMPLATE"
is "validate: fifteen empties, fifteen problems" "15" \
  "$(printf '%s\n' "$CT_CONFIG_PROBLEMS" | grep -c 'is not valid')"
contains "validate: an empty toggle is a problem" \
  "ENABLED= is not valid, using on" "$CT_CONFIG_PROBLEMS"
lacks "validate: an empty timezone is not" "TZ= is not valid" "$CT_CONFIG_PROBLEMS"
lacks "validate: nor an empty part colour"  "TIME_COLOR= is not valid" "$CT_CONFIG_PROBLEMS"
lacks "validate: nor an empty marker"       "MARKER= is not valid" "$CT_CONFIG_PROBLEMS"

# No hook may be aborted by a typo in the config file. The values are assigned
# here rather than loaded from a file because the loader has already replaced
# them by the time it returns, and the claim is about what the validator does
# while they are still unusable.
fresh
CT_ENABLED=maybe
CT_TZ='../etc'
CT_DISPLAY_FORMAT=wat
CT_COLOR=banana
CT_MARKER_TEMPLATE='%elapsd'
CT_SLOW_AFTER=soon
CT_HISTORY_LIMIT=0
CT_INJECT_CONTEXT=perhaps
ct_rc=0
ct_validate_config || ct_rc=$?
is "validate: an unusable config is still a success" "0" "$ct_rc"
is "validate: and it repaired every one of them anyway" \
  "on||24h|dim|60|200|true" \
  "$CT_ENABLED|$CT_TZ|$CT_DISPLAY_FORMAT|$CT_COLOR|$CT_SLOW_AFTER|$CT_HISTORY_LIMIT|$CT_INJECT_CONTEXT"

# And it says none of it out loud. message-display.sh writes JSON to stdout, so
# a validator that printed would corrupt the hook's output on every message;
# session-start.sh and --doctor read CT_CONFIG_PROBLEMS instead, at the one
# moment somebody is looking.
printf '%s\n' "${ct_bad_conf[@]}" > "$CLAUDE_TIMESTAMP_CONFIG"
is "validate: loading the worst config there is prints nothing at all" \
  "" "$(ct_load_config 2>&1)"

# --- _ct_require ------------------------------------------------------------
#
# The one place a rejected setting turns into a sentence the user can act on.
# Driven directly rather than through ct_load_config, because everything that
# can go wrong in here -- which value gets named, under which key, and how two
# of them are joined -- is invisible once twenty calls have run in a row.
#
# A name beginning with REQ_ is not a setting, so a case can exercise the
# CT_<NAME> indirection without disturbing the config around it.
fresh

CT_CONFIG_PROBLEMS="  a line that was already there"
CT_COLOR="cyan"
asserts "require: an accepted value returns 0" _ct_require COLOR ct_is_valid_color dim
is "require: and leaves the setting untouched" "cyan" "$CT_COLOR"
is "require: and appends nothing" "  a line that was already there" "$CT_CONFIG_PROBLEMS"

# The check is handed the value currently in CT_<NAME> -- not the name, not the
# default. A predicate reading the wrong string would accept and reject the
# wrong configs while every message here still looked right.
CT_REQ_SPY_SEEN=""
# shellcheck disable=SC2317  # _ct_require calls this by name, not from here
ct_req_spy() { CT_REQ_SPY_SEEN="$1"; [ "$1" = "keep" ]; }
CT_CONFIG_PROBLEMS=""
CT_REQ_SPY="keep"
_ct_require REQ_SPY ct_req_spy fallback
is "require: the check is given the value of CT_<NAME>" "keep" "$CT_REQ_SPY_SEEN"
is "require: and an accepted value survives" "keep" "$CT_REQ_SPY"

CT_REQ_SPY="drop"
_ct_require REQ_SPY ct_req_spy fallback
is "require: a rejected value is replaced by the default" "fallback" "$CT_REQ_SPY"
is "require: and one line says why" \
   "  REQ_SPY=drop is not valid, using fallback" "$CT_CONFIG_PROBLEMS"

# Every hook runs under `set -e` and calls ct_load_config as a plain command,
# whose last statement is one of these. A non-zero return on a rejected value
# would kill the hook over a typo in a config file.
CT_CONFIG_PROBLEMS=""
CT_REQ_SPY="drop"
asserts "require: rejecting still returns 0, so a hook under set -e survives" \
        _ct_require REQ_SPY ct_req_spy fallback

# The sentence must quote what the user wrote. Naming the replacement instead
# -- "COLOR=dim is not valid, using dim" -- is the failure this pins.
CT_CONFIG_PROBLEMS=""
CT_COLOR="banana"
_ct_require COLOR ct_is_valid_color dim
# Pinned whole, so the two-space indent session-start.sh relies on is part of
# what this asserts rather than a separate check that cannot fail on its own.
is "require: the report names the original value, not its replacement" \
   "  COLOR=banana is not valid, using dim" "$CT_CONFIG_PROBLEMS"

# MARKER_TEMPLATE is stored under a name no config file ever spells, which is
# the whole reason the fourth parameter exists.
CT_CONFIG_PROBLEMS=""
CT_MARKER_TEMPLATE="%elapsd"
_ct_require MARKER_TEMPLATE ct_is_valid_marker '[%time]' MARKER
# The whole string, which is also what rules out the internal name leaking into
# the sentence: "MARKER_TEMPLATE=" cannot be in a line pinned to this.
is "require: the fourth parameter renames the report" \
   "  MARKER=%elapsd is not valid, using [%time]" "$CT_CONFIG_PROBLEMS"
is "require: while the variable written is still the internal one" \
   "[%time]" "$CT_MARKER_TEMPLATE"

# Two failures joined by exactly one newline, with none in front: the ${VAR:+}
# guard is what keeps the first line off a blank one, and session-start.sh
# prints this block verbatim.
CT_CONFIG_PROBLEMS=""
CT_COLOR="banana"
CT_ELAPSED="maybe"
_ct_require COLOR   ct_is_valid_color dim
_ct_require ELAPSED ct_is_onoff       on
is "require: two failures are two lines joined by one newline" \
   "  COLOR=banana is not valid, using dim
  ELAPSED=maybe is not valid, using on" "$CT_CONFIG_PROBLEMS"

# It appends rather than resetting. ct_validate_config clears the report once
# and then calls this twenty times; a reset in here would leave only whichever
# bad setting happened to come last.
CT_CONFIG_PROBLEMS="  SLOW_AFTER=abc is not valid, using 60"
CT_COLOR="banana"
_ct_require COLOR ct_is_valid_color dim
# Pinned as the whole string rather than as a `contains` for each line: order is
# part of the claim, and the earlier line surviving is already inside it. A
# version that put the new line in FRONT of the earlier one still kept both, so
# a pair of substring checks passed while session-start.sh printed the twenty
# settings in the wrong order.
is "require: and the new line goes after it, not in front" \
   "  SLOW_AFTER=abc is not valid, using 60
  COLOR=banana is not valid, using dim" "$CT_CONFIG_PROBLEMS"

# A setting that is empty and refused reads as "KEY=" rather than losing the
# key or the rule around it.
CT_CONFIG_PROBLEMS=""
CT_SLOW_AFTER=""
_ct_require SLOW_AFTER ct_is_seconds 60
is "require: an empty value still produces a whole sentence" \
   "  SLOW_AFTER= is not valid, using 60" "$CT_CONFIG_PROBLEMS"

# A value carrying an '=' or a run of spaces is echoed back byte for byte, so
# the user can match it against the line they typed.
CT_CONFIG_PROBLEMS=""
CT_DISPLAY_FORMAT="a = b  c"
_ct_require DISPLAY_FORMAT ct_is_valid_format 24h
is "require: an awkward value is reproduced verbatim" \
   "  DISPLAY_FORMAT=a = b  c is not valid, using 24h" "$CT_CONFIG_PROBLEMS"

# The spy is a CT_* variable that is not a setting, and parse_dump enumerates
# that namespace with ${!CT_@}. Cleared so nothing added after this point
# inherits a name the config reader never writes.
unset -f ct_req_spy
unset CT_REQ_SPY CT_REQ_SPY_SEEN
fresh

echo
echo "projects setting"

: > "$CLAUDE_TIMESTAMP_CONFIG"
ct_load_config
is "projects: defaults to off" "off" "$CT_PROJECTS"

printf 'PROJECTS=on\n' > "$CLAUDE_TIMESTAMP_CONFIG"
ct_load_config
is "projects: on is read" "on" "$CT_PROJECTS"

printf 'PROJECTS=maybe\n' > "$CLAUDE_TIMESTAMP_CONFIG"
ct_load_config
is "projects: an invalid value falls back to the default" "off" "$CT_PROJECTS"
contains "projects: and says so" "PROJECTS=maybe is not valid" "$CT_CONFIG_PROBLEMS"

echo
echo "settings apply without a restart"

# Every hook re-reads the config, so a change is live on the next message.
# Three places used to tell people otherwise.
if command -v jq >/dev/null 2>&1; then
  fresh 'COLOR=none' 'ELAPSED=off' 'IDLE_AFTER=0' 'DATE_ROLLOVER=off' 'DISPLAY_FORMAT=24h'
  before="$(printf '{"session_id":"live","index":0,"delta":"x"}' | bash "$SCRIPTS/message-display.sh" | jq -r '.hookSpecificOutput.displayContent')"
  printf 'COLOR=none\nELAPSED=off\nIDLE_AFTER=0\nDATE_ROLLOVER=off\nDISPLAY_FORMAT=iso\n' > "$CLAUDE_TIMESTAMP_CONFIG"
  after="$(printf '{"session_id":"live","index":0,"delta":"x"}' | bash "$SCRIPTS/message-display.sh" | jq -r '.hookSpecificOutput.displayContent')"
  case "$before" in *T*) fail "the marker starts in the short format" "no date" "$before" ;; *) pass "the marker starts in the short format" ;; esac
  contains "changing the config applies to the very next message" "T" "$after"
fi

lacks "setup no longer claims a restart is needed" "Restart Claude Code" "$(cat "$SCRIPTS/setup.sh")"
contains "setup says the change is immediate" "next message" "$(cat "$SCRIPTS/setup.sh")"

echo
echo "the wizard"

fresh
# The timezone answer depends on the platform. Where there is no timezone
# database the wizard is right to refuse a pinned zone, and feeding it one
# would make it re-ask and swallow every later answer, which is exactly how
# this test first failed on Windows.
if ct_tz_supported; then
  tz_answer="Asia/Tokyo"
  tz_expected="Asia/Tokyo"
else
  tz_answer="local"
  tz_expected=""
fi

# Answers in prompt order: enabled, timezone, display format, elapsed, slow
# after, idle after, summary, tool timing, history, projects, colour, marker
# (blank keeps the default), tell-Claude, write. Tool timing is asked
# unconditionally now, regardless of what summary answered -- it feeds the
# session history and --stats, not just the on-screen summary any more.
# Context format is skipped because tell-Claude is answered false.
printf 'off\n%s\nshort\non\n30\n0\noff\noff\non\noff\ncyan\n\nfalse\ny\n' "$tz_answer" \
  | bash "$SCRIPTS/setup.sh" >/dev/null 2>&1
ct_load_config
is "the wizard writes enabled"        "off"        "$CT_ENABLED"
is "the wizard writes the timezone"   "$tz_expected" "$CT_TZ"
is "the wizard writes the format"     "short"      "$CT_DISPLAY_FORMAT"
is "the wizard writes the threshold"  "30"         "$CT_SLOW_AFTER"
is "the wizard writes the colour"     "cyan"       "$CT_COLOR"
is "the wizard writes the summary"    "off"        "$CT_SUMMARY"
is "the wizard writes the injection"  "false"      "$CT_INJECT_CONTEXT"

# Answering off then back on in a fresh run proves the question round-trips
# rather than only ever moving in one direction.
fresh 'ENABLED=off'
printf 'on\n%s\nshort\non\n30\n0\noff\noff\non\noff\ncyan\n\nfalse\ny\n' "$tz_answer" \
  | bash "$SCRIPTS/setup.sh" >/dev/null 2>&1
ct_load_config
is "the wizard round-trips enabled back on" "on" "$CT_ENABLED"

# Summary is answered on here, so tool timing was already being asked at this
# point before this fix -- nothing about this fixture's answer count changes.
fresh 'COLOR=green'
printf 'off\nlocal\niso\non\n0\n0\non\non\non\non\nred\n\ntrue\n24h\nn\n' \
  | bash "$SCRIPTS/setup.sh" >/dev/null 2>&1
ct_load_config
is "answering no writes nothing"          "green" "$CT_COLOR"
is "answering no leaves enabled untouched" "on"    "$CT_ENABLED"

fresh
printf 'on\nlocal\nshort\non\n30\n0\noff\noff\non\non\ncyan\n\nfalse\ny\n' \
  | bash "$SCRIPTS/setup.sh" >/dev/null 2>&1
ct_load_config
is "the wizard writes history"  "on" "$CT_HISTORY"
is "the wizard writes projects" "on" "$CT_PROJECTS"

# Answering the history question off must skip the projects question rather
# than ask one whose answer cannot take effect. If it were asked anyway, the
# colour answer below would be swallowed by it and the colour assertion would
# catch that.
fresh
printf 'on\nlocal\nshort\non\n30\n0\noff\noff\noff\ncyan\n\nfalse\ny\n' \
  | bash "$SCRIPTS/setup.sh" >/dev/null 2>&1
ct_load_config
is "the wizard writes history off"            "off"   "$CT_HISTORY"
is "history off skips the projects question"  "cyan"  "$CT_COLOR"
is "and leaves projects at its default"       "off"   "$CT_PROJECTS"

# Input running out must not leave the wizard asking forever.
fresh
if timeout 20 bash -c "printf 'local\\n' | bash '$SCRIPTS/setup.sh' >/dev/null 2>&1"; then
  pass "the wizard finishes when input runs out"
else
  status=$?
  if [ "$status" -eq 124 ]; then
    fail "the wizard finishes when input runs out" "an exit" "still waiting after 20s"
  else
    pass "the wizard finishes when input runs out"
  fi
fi

# The wizard re-asks until it gets a usable answer. When stdin is exhausted it
# must stop rather than spin: the default it keeps offering can itself be
# invalid, which is what a TZ environment variable naming a zone this machine
# does not have produces.
#
# Three assertions, because "it exited" is not the claim being made. A wizard
# that died on an unrelated error before reaching a single question also exits
# non-124, and would pass a bare termination check while proving nothing about
# the EOF plumbing. So this also pins that it got as far as the timezone
# question -- the loop that used to spin -- and that it ran all the way out to
# the write confirmation rather than stopping there.
#
# Note the output is captured rather than discarded. On a regression the wizard
# spins printing prompts, so this file can grow large before the timeout fires;
# it lives in $WORK, which the suite's EXIT trap removes.
if command -v timeout >/dev/null 2>&1; then
  eof_out="$WORK/wizard-eof.out"
  rc=0
  timeout 10 env TZ=Mars/Olympus HOME="$WORK" \
    CLAUDE_TIMESTAMP_CONFIG="$WORK/wizard-eof.conf" \
    bash "$SCRIPTS/setup.sh" </dev/null > "$eof_out" 2>&1 || rc=$?
  if [ "$rc" -eq 124 ]; then
    fail "wizard: terminates on exhausted stdin with an invalid default" \
         "an exit" "timed out after 10s"
  else
    pass "wizard: terminates on exhausted stdin with an invalid default"
  fi
  contains "wizard: reached the timezone question before giving up" \
           "Timezone" "$(cat "$eof_out")"
  contains "wizard: ran through to the write confirmation" \
           "Write this configuration?" "$(cat "$eof_out")"
else
  echo "  skip timeout not installed, wizard EOF case not run"
fi

echo
echo "session history"

fresh
is "history goes where it is told" "$CLAUDE_TIMESTAMP_HISTORY" "$(ct_history_path)"

ct_history_append 3600 12 900 300 2
is "a session is one row"      "1" "$(wc -l < "$CLAUDE_TIMESTAMP_HISTORY" | tr -d ' ')"
is "a row carries six fields"  "6" "$(awk -F'\t' 'NR==1{print NF}' "$CLAUDE_TIMESTAMP_HISTORY")"
is "the duration is recorded"  "3600" "$(awk -F'\t' 'NR==1{print $2}' "$CLAUDE_TIMESTAMP_HISTORY")"
is "the turns are recorded"    "12"   "$(awk -F'\t' 'NR==1{print $3}' "$CLAUDE_TIMESTAMP_HISTORY")"
is "the failures are recorded" "2"    "$(awk -F'\t' 'NR==1{print $6}' "$CLAUDE_TIMESTAMP_HISTORY")"

: > "$CLAUDE_TIMESTAMP_HISTORY"
ct_history_append 3600 12 900 300 2
is "row: five arguments still write six fields" \
   "6" "$(awk -F'\t' 'NR==1{print NF}' "$CLAUDE_TIMESTAMP_HISTORY")"

: > "$CLAUDE_TIMESTAMP_HISTORY"
ct_history_append 3600 12 900 300 2 "myrepo"
is "row: a project makes it seven fields" \
   "7" "$(awk -F'\t' 'NR==1{print NF}' "$CLAUDE_TIMESTAMP_HISTORY")"
is "row: and the project lands in field seven" \
   "myrepo" "$(cut -f7 "$CLAUDE_TIMESTAMP_HISTORY")"

: > "$CLAUDE_TIMESTAMP_HISTORY"
ct_history_append 3600 12 900 300 2 "" "Bash:20:2"
is "row: tools without a project still make it eight fields" \
   "8" "$(awk -F'\t' 'NR==1{print NF}' "$CLAUDE_TIMESTAMP_HISTORY")"
is "row: and field seven is a dash rather than empty" \
   "-" "$(cut -f7 "$CLAUDE_TIMESTAMP_HISTORY")"
is "row: and the digest lands in field eight" \
   "Bash:20:2" "$(cut -f8 "$CLAUDE_TIMESTAMP_HISTORY")"

: > "$CLAUDE_TIMESTAMP_HISTORY"
ct_history_append 3600 12 900 300 2 "myrepo" "Bash:20:2"
is "row: both make it eight fields" \
   "8" "$(awk -F'\t' 'NR==1{print NF}' "$CLAUDE_TIMESTAMP_HISTORY")"
is "row: no field is ever written empty" \
   "0" "$(grep -c $'\t\t' "$CLAUDE_TIMESTAMP_HISTORY" || true)"

fresh 'HISTORY_LIMIT=3'
for i in 1 2 3 4 5 6; do ct_history_append "$i" 1 0 0 0; done
is "the retention limit is applied" "3" "$(wc -l < "$CLAUDE_TIMESTAMP_HISTORY" | tr -d ' ')"
is "the newest rows are the ones kept" "6" "$(awk -F'\t' 'END{print $2}' "$CLAUDE_TIMESTAMP_HISTORY")"

# Two sessions ending at once both append and then both trim, and the trim is
# read-then-replace: without a lock the second overwrites the first's line.
fresh 'HISTORY_LIMIT=5'
rm -f "$CLAUDE_TIMESTAMP_HISTORY"
for i in 1 2 3 4 5 6 7 8; do ct_history_append "$i" 1 0 0 0; done
is "history: trims to the limit" "5" "$(wc -l < "$CLAUDE_TIMESTAMP_HISTORY" | tr -d ' ')"
is "history: keeps the newest" "8" "$(tail -1 "$CLAUDE_TIMESTAMP_HISTORY" | cut -f2)"

rm -f "$CLAUDE_TIMESTAMP_HISTORY"
for i in 1 2 3 4 5 6; do ( ct_history_append "$i" 1 0 0 0 ) & done
wait
# What the lock guarantees is that no appended line is lost, not that the trim
# always runs: a writer that loses the race skips its trim, which leaves one
# extra line for the next append to remove. Assert the property the design
# actually has.
lines="$(wc -l < "$CLAUDE_TIMESTAMP_HISTORY" | tr -d ' ')"
if [ "$lines" -ge 5 ] && [ "$lines" -le 6 ]; then
  pass "history: concurrent appends leave the file at the limit, give or take one skipped trim"
else
  fail "history: concurrent appends leave the file at the limit, give or take one skipped trim" \
       "5 or 6 lines" "$lines"
fi
# This used to assert that the append labelled 6 survived, which is not a
# property this system has, for two separate reasons.
#
# The six writers run concurrently, so they finish in whatever order the
# scheduler hands out. The trim keeps the last lines in file order, which is
# completion order and not label order, so the one labelled 6 is trimmed away
# legitimately whenever it happens to finish early. That is true even with a
# lock that works perfectly.
#
# On top of that, a writer that waits out the lock appends unprotected, which
# ct_history_append says plainly: with the lock no append can be lost, without
# it this one might be. On an idle machine that never showed up; under CPU
# load it cost an append in 6 runs out of 40. Naming a particular survivor is
# a red build waiting for a busy runner.
#
# So assert the property the design does have: whatever survived the trim is
# intact and distinct. The line count either side of this covers how many
# survived; this covers whether concurrent writers corrupted each other, which
# is what a broken lock would actually look like.
survivors="$(cut -f2 "$CLAUDE_TIMESTAMP_HISTORY")"
is "history: no surviving append was written over another" \
   "$(printf '%s\n' "$survivors" | wc -l | tr -d ' ')" \
   "$(printf '%s\n' "$survivors" | sort -u | wc -l | tr -d ' ')"
is "history: every surviving append is one that was made" "0" \
   "$(printf '%s\n' "$survivors" | grep -cvE '^[1-6]$' || true)"

# A lock left behind by a process that died between mkdir and rmdir must not
# silently defeat HISTORY_LIMIT for the rest of the installation's life.
# Nothing holds this lock longer than a tail takes, so a lock old enough to
# be debris rather than a live competitor gets reclaimed and the trim
# resumes. A fixed date in the past rather than a relative one: GNU touch
# spells that -d '2 minutes ago' and BSD touch spells it -v-2M, but -t works
# on both.
fresh 'HISTORY_LIMIT=5'
rm -f "$CLAUDE_TIMESTAMP_HISTORY"
for i in 1 2 3 4; do ct_history_append "$i" 1 0 0 0; done
mkdir "$CLAUDE_TIMESTAMP_HISTORY.lock"
touch -t 200001010000 "$CLAUDE_TIMESTAMP_HISTORY.lock"
ct_history_append 5 1 0 0 0
ct_history_append 6 1 0 0 0
is "history: a stale lock is reclaimed and trimming resumes" "5" \
   "$(wc -l < "$CLAUDE_TIMESTAMP_HISTORY" | tr -d ' ')"
is "history: the newest row survives past a reclaimed lock" "6" \
   "$(tail -1 "$CLAUDE_TIMESTAMP_HISTORY" | cut -f2)"
if [ -d "$CLAUDE_TIMESTAMP_HISTORY.lock" ]; then
  fail "history: a reclaimed lock is removed, not left behind again" "gone" "still present"
else
  pass "history: a reclaimed lock is removed, not left behind again"
fi

# A lock that is not stale is a live competitor, not debris: it must be left
# alone, and the trim it is guarding must be skipped rather than forced.
fresh 'HISTORY_LIMIT=5'
rm -f "$CLAUDE_TIMESTAMP_HISTORY"
rmdir "$CLAUDE_TIMESTAMP_HISTORY.lock" 2>/dev/null || true
for i in 1 2 3 4 5; do ct_history_append "$i" 1 0 0 0; done
mkdir "$CLAUDE_TIMESTAMP_HISTORY.lock"
ct_history_append 6 1 0 0 0
is "history: a live lock's trim is skipped, not forced" "6" \
   "$(wc -l < "$CLAUDE_TIMESTAMP_HISTORY" | tr -d ' ')"
if [ -d "$CLAUDE_TIMESTAMP_HISTORY.lock" ]; then
  pass "history: a live lock is left in place"
else
  fail "history: a live lock is left in place" "still present" "gone"
fi
rmdir "$CLAUDE_TIMESTAMP_HISTORY.lock" 2>/dev/null || true

fresh 'HISTORY_LIMIT=nonsense'
is "a nonsense limit falls back" "200" "$CT_HISTORY_LIMIT"

# HISTORY_LIMIT=0 reads as "keep none" by analogy with SLOW_AFTER and
# IDLE_AFTER, both of which document 0 as disabling -- but the real off switch
# is HISTORY=off, and 0 here used to be silently clamped up to 1. A hand-
# edited config that says 0 must fall back to the default like any other
# unusable value, not be quietly reinterpreted as 1.
fresh 'HISTORY_LIMIT=0'
is "a history limit of 0 falls back to the default" "200" "$CT_HISTORY_LIMIT"

# Every rendered time honours a pinned zone. History was the exception, which
# put the recorded date a day out from every timestamp the user ever saw, and
# --stats renders exactly the date half of it.
fresh 'TZ=Asia/Tokyo' 'HISTORY=on'
rm -f "$CLAUDE_TIMESTAMP_HISTORY"
ct_history_append 10 1 5 0 0
is "history: the row is stamped in the pinned zone" \
   "$(TZ=Asia/Tokyo date '+%Y-%m-%dT%H:%M')" "$(cut -f1 "$CLAUDE_TIMESTAMP_HISTORY" | cut -c1-16)"

# HISTORY and SUMMARY are separate settings, so switching the end-of-session
# report off must not silently switch the running record off with it. The
# counters they share are written unconditionally; only the reporting is gated.
fresh 'SUMMARY=off' 'HISTORY=on'
printf '{"session_id":"hist-nosummary","cwd":"%s"}' "$WORK" \
  | bash "$SCRIPTS/user-prompt-submit.sh" >/dev/null
printf '{"index":0,"session_id":"hist-nosummary","cwd":"%s","delta":"x"}' "$WORK" \
  | bash "$SCRIPTS/message-display.sh" >/dev/null
printf '{"session_id":"hist-nosummary","cwd":"%s"}' "$WORK" \
  | bash "$SCRIPTS/stop.sh" >/dev/null
printf '{"session_id":"hist-nosummary","cwd":"%s"}' "$WORK" \
  | bash "$SCRIPTS/session-end.sh" >/dev/null
is "history: recorded even with the summary off" "1" \
   "$(wc -l < "$CLAUDE_TIMESTAMP_HISTORY" | tr -d ' ')"

# And the summary itself still says nothing, because that is what SUMMARY=off
# asks for. The two settings are independent in both directions.
fresh 'SUMMARY=off' 'HISTORY=on'
printf '{"session_id":"hist-quiet","cwd":"%s"}' "$WORK" \
  | bash "$SCRIPTS/user-prompt-submit.sh" >/dev/null
printf '{"session_id":"hist-quiet","cwd":"%s"}' "$WORK" \
  | bash "$SCRIPTS/stop.sh" >/dev/null
is "history: the summary stays silent with SUMMARY=off" "" \
   "$(printf '{"session_id":"hist-quiet","cwd":"%s"}' "$WORK" | bash "$SCRIPTS/session-end.sh")"

if command -v jq >/dev/null 2>&1; then
  echo
  echo "what a session adds up to"

  seed_session() {
    # $1 seconds ago it started, $2 turns, $3 waited, $4 idle, $5 failed calls
    local b i; b="$(ct_state_file "acct2")"
    mkdir -p "$(ct_state_dir)"
    printf '%s' "$(( $(date +%s) - $1 ))" > "$b.start"
    printf '%s' "$2" > "$b.turns"
    printf '%s' "$3" > "$b.wait"
    [ "${4:-0}" -gt 0 ] && printf '%s' "$4" > "$b.idle"
    # Failures live on the tool log's third field now, so a seeded failure is a
    # seeded log line rather than a counter.
    i=0
    while [ "$i" -lt "${5:-0}" ]; do
      printf 'Bash 1.0 fail\n' >> "$b.tools"
      i=$((i + 1))
    done
    return 0
  }
  end_session() { printf '{"session_id":"acct2"}' | bash "$SCRIPTS/session-end.sh" | jq -r '.systemMessage // ""'; }

  fresh
  seed_session 5400 9 754 2100 0
  out="$(end_session)"
  contains "the summary reports time away" "35m00s away" "$out"

  fresh
  seed_session 5400 9 754 0 0
  out="$(end_session)"
  lacks "a session with no breaks does not mention being away" "away" "$out"

  fresh 'TOOL_TIMING=on'
  seed_session 600 3 120 0 2
  out="$(end_session)"
  contains "the summary counts failed tool calls" "2 failed" "$out"

  fresh
  seed_session 600 3 120 0 0
  end_session >/dev/null
  is "a finished session is recorded" "1" "$(wc -l < "$CLAUDE_TIMESTAMP_HISTORY" | tr -d ' ')"

  fresh 'HISTORY=off'
  seed_session 600 3 120 0 0
  end_session >/dev/null
  if [ -s "$CLAUDE_TIMESTAMP_HISTORY" ]; then
    fail "HISTORY=off records nothing" "no file" "rows were written"
  else
    pass "HISTORY=off records nothing"
  fi

  fresh
  out="$(printf '{"session_id":"never"}' | bash "$SCRIPTS/session-end.sh")"
  if [ -s "$CLAUDE_TIMESTAMP_HISTORY" ]; then
    fail "a session with no turns is not recorded" "no rows" "a row was written"
  else
    pass "a session with no turns is not recorded"
  fi

  echo
  echo "counting time away and failures"

  # The break is now measured and accumulated by the prompt hook, from the
  # previous turn's close, not drawn on screen by message-display.sh.
  fresh 'COLOR=none' 'ELAPSED=off' 'IDLE_AFTER=3600' 'DATE_ROLLOVER=off'
  printf '%s' "$(( $(date +%s) - 7200 ))" > "$(ct_state_dir)/gap.closed"
  printf '{"session_id":"gap","cwd":"%s"}' "$WORK" | bash "$SCRIPTS/user-prompt-submit.sh" >/dev/null
  is_near "a marked break is added to the time away" 7200 "$(ct_read_counter "$(ct_state_dir)/gap.idle")" 3

  # ct_record_away, ct_take_away and ct_note_message directly, exercising the
  # edge cases the hooks rely on but do not spell out themselves.
  fresh 'IDLE_AFTER=1800'
  base="$(ct_state_file "away-fn")"
  ct_clear_state "away-fn"; mkdir -p "$(ct_state_dir)"

  # The first prompt of a session has no .closed: nothing recorded, nothing
  # staged.
  ct_record_away "away-fn" "$(date +%s)"
  is "ct_record_away: no .closed records nothing" "0" "$(ct_read_counter "$base.idle")"
  is "ct_record_away: no .closed stages nothing"   "0" "$(ct_read_counter "$base.away")"

  # A gap under the threshold: recorded and staged nowhere.
  now="$(date +%s)"
  printf '%s' "$(( now - 100 ))" > "$base.closed"
  ct_record_away "away-fn" "$now"
  is "ct_record_away: under the threshold records nothing" "0" "$(ct_read_counter "$base.idle")"
  is "ct_record_away: under the threshold stages nothing"   "0" "$(ct_read_counter "$base.away")"

  # A gap over the threshold: added to .idle, and written to .away.
  now="$(date +%s)"
  printf '%s' "$(( now - 3600 ))" > "$base.closed"
  ct_record_away "away-fn" "$now"
  is_near "ct_record_away: a real gap is added to .idle"  3600 "$(ct_read_counter "$base.idle")" 2
  is_near "ct_record_away: a real gap is staged in .away" 3600 "$(ct_read_counter "$base.away")" 2

  # A second gap replaces the staged figure rather than piling onto it -- a
  # turn that drew no message of its own must not leave a stale break behind
  # for the divider to draw twice over.
  printf '%s' "$(( now - 1800 ))" > "$base.closed"
  ct_record_away "away-fn" "$now"
  is_near "ct_record_away: .away is replaced, not accumulated" 1800 "$(ct_read_counter "$base.away")" 2
  is_near "ct_record_away: .idle keeps accumulating"           5400 "$(ct_read_counter "$base.idle")" 3

  # IDLE_AFTER=0 disables the feature entirely: accumulate nothing, stage
  # nothing, even against a gap that would otherwise clearly qualify.
  fresh 'IDLE_AFTER=0'
  ct_clear_state "away-fn"; mkdir -p "$(ct_state_dir)"
  printf '%s' "$(( $(date +%s) - 7200 ))" > "$base.closed"
  ct_record_away "away-fn" "$(date +%s)"
  is "ct_record_away: IDLE_AFTER=0 records nothing" "0" "$(ct_read_counter "$base.idle")"
  is "ct_record_away: IDLE_AFTER=0 stages nothing"   "0" "$(ct_read_counter "$base.away")"

  # ct_take_away prints the staged gap and clears it in the same call.
  fresh 'IDLE_AFTER=1800'
  ct_clear_state "away-fn"; mkdir -p "$(ct_state_dir)"
  printf '2100' > "$base.away"
  is "ct_take_away: prints the staged gap" "2100" "$(ct_take_away "away-fn")"
  is "ct_take_away: clears what it printed" ""     "$(ct_take_away "away-fn")"

  # ct_note_message writes .last and touches nothing else.
  ct_clear_state "away-fn"; mkdir -p "$(ct_state_dir)"
  ct_note_message "away-fn" "12345"
  is "ct_note_message: writes .last"          "12345" "$(cat "$base.last")"
  is "ct_note_message: does not touch .idle"  "0"      "$(ct_read_counter "$base.idle")"

  # Waiting and away are disjoint intervals that tile the session, so their sum
  # can never exceed the elapsed total. It used to: away was measured from the
  # previous message rather than the previous turn's close, so it swallowed the
  # tail of that turn, which waiting had already counted.
  fresh 'IDLE_AFTER=3600' 'SUMMARY=on'
  sid="tiling"
  base="$(ct_state_file "$sid")"
  now="$(date +%s)"
  # Turn 1: prompted 7200s ago, last message 3700s ago, closed 3700s ago.
  # Then away 3600s. Turn 2: prompted 100s ago, closing now.
  printf '%s' "$(( now - 7200 ))" > "$base.start"
  printf '%s' "$(( now - 7200 ))" > "$base"
  printf '%s' "$(( now - 3700 ))" > "$base.last"
  printf '%s' "$(( now - 3700 ))" > "$base.closed"
  printf '%s' "3500"              > "$base.wait"
  printf '1'                      > "$base.turns"

  printf '{"session_id":"%s","cwd":"%s"}' "$sid" "$WORK" \
    | bash "$SCRIPTS/user-prompt-submit.sh" >/dev/null
  is_near "away: measured from the turn close, not the last message" \
          3700 "$(ct_read_counter "$base.idle")" 2

  # Drawing a message must not touch the idle total any more. This is the
  # assertion that actually fails against the old code: message-display.sh used
  # to accumulate `.idle` itself, from a boundary that swallowed the reply's own
  # latency. The measurement now belongs to the prompt hook, and the display
  # hook only draws what was staged for it.
  idle_before="$(ct_read_counter "$base.idle")"
  printf '{"index":0,"session_id":"%s","cwd":"%s","delta":"reply"}' "$sid" "$WORK" \
    | bash "$SCRIPTS/message-display.sh" >/dev/null
  is "away: drawing a message does not change the idle total" \
     "$idle_before" "$(ct_read_counter "$base.idle")"

  printf '{"session_id":"%s","cwd":"%s"}' "$sid" "$WORK" | bash "$SCRIPTS/stop.sh" >/dev/null
  ct_session_totals "$sid"
  elapsed=$(( $(date +%s) - _CT_START ))
  if [ "$(( _CT_WAIT + _CT_IDLE ))" -le "$elapsed" ]; then
    pass "away: waiting plus away never exceeds the session"
  else
    fail "away: waiting plus away never exceeds the session" \
         "at most $elapsed" "$(( _CT_WAIT + _CT_IDLE ))"
  fi

  # A staged gap must not outlive the boundary it belongs to. A turn that closes
  # after a real break but renders no message -- a tool-only turn, or one
  # interrupted before any text streamed -- leaves its figure staged. The next
  # boundary must clear it, or a later and entirely unrelated message draws a
  # divider for a break that never happened, and the model is told the same.
  fresh 'IDLE_AFTER=3600' 'SUMMARY=on'
  sid="stale"
  base="$(ct_state_file "$sid")"
  now="$(date +%s)"
  printf '%s' "$(( now - 7200 ))" > "$base.closed"
  ct_record_away "$sid" "$now"
  is "away: a qualifying gap is staged" "7200" "$(ct_read_counter "$base.away")"

  printf '%s' "$(( now - 10 ))" > "$base.closed"
  ct_record_away "$sid" "$now"
  is "away: a non-qualifying boundary clears the stale figure" \
     "0" "$(ct_read_counter "$base.away")"

  # ct_session_totals clamps rather than trusting the counters, because a clock
  # that moved backwards can leave a figure larger than the session it belongs
  # to. The tiling assertion above cannot catch a clamp regression: it reads the
  # values *after* the clamp has already applied. This exercises the clamp
  # itself, which is the thing that assertion was standing in for.
  fresh
  sid="clamp"
  base="$(ct_state_file "$sid")"
  now="$(date +%s)"
  printf '%s' "$(( now - 100 ))" > "$base.start"
  printf '900' > "$base.wait"
  printf '900' > "$base.idle"
  ct_session_totals "$sid"
  is_near "clamp: waiting alone cannot exceed the session" 100 "$_CT_WAIT" 2
  is      "clamp: away never goes negative"                "0" "$_CT_IDLE"

  fresh
  sid="clamp2"
  base="$(ct_state_file "$sid")"
  now="$(date +%s)"
  printf '%s' "$(( now - 100 ))" > "$base.start"
  printf '60'  > "$base.wait"
  printf '900' > "$base.idle"
  ct_session_totals "$sid"
  is      "clamp: waiting under the total is left alone" "60" "$_CT_WAIT"
  is_near "clamp: away absorbs the overflow"             40 "$_CT_IDLE" 2

  fresh 'TOOL_TIMING=on'
  ct_stage_flag "f" "timing-on" "1"
  printf '{"session_id":"f","tool_use_id":"t1","tool_name":"Bash","duration_ms":1000,"hook_event_name":"PostToolUseFailure"}' \
    | bash "$SCRIPTS/post-tool-use.sh"
  is "a failed call is still timed" "1" "$(wc -l < "$(ct_tool_log f)" | tr -d ' ')"
  is "a failed call records its outcome" "1" "$(grep -c ' fail$' "$(ct_tool_log f)")"

  printf '{"session_id":"f","tool_use_id":"t2","tool_name":"Bash","duration_ms":1000,"hook_event_name":"PostToolUse"}' \
    | bash "$SCRIPTS/post-tool-use.sh"
  is "a successful call is not recorded as failed" "1" "$(grep -c ' fail$' "$(ct_tool_log f)")"
fi

echo
echo "stats"

fresh
out="$(bash "$SCRIPTS/setup.sh" --stats)"
contains "stats says when there is nothing yet" "No sessions recorded yet" "$out"

fresh 'HISTORY=off'
contains "stats explains a switched-off history" "switched off" "$(bash "$SCRIPTS/setup.sh" --stats)"

fresh
printf '2026-08-11T09:00:00\t1200\t7\t300\t200\t1\n2026-08-12T09:00:00\t2400\t14\t600\t400\t0\n' \
  > "$CLAUDE_TIMESTAMP_HISTORY"
out="$(bash "$SCRIPTS/setup.sh" --stats)"
contains "stats counts the sessions"    "sessions        2"  "$out"
contains "stats totals the time"        "1h00m"              "$out"
contains "stats totals the turns"       "turns           21" "$out"
contains "stats names the longest"      "2026-08-12"         "$out"
contains "stats reports the range"      "recorded from"      "$out"
contains "stats counts failures"        "failed tools    1"  "$out"

# A damaged history row must be reported, not silently shifted into the
# wrong columns.
fresh 'HISTORY=on'
printf '2026-08-20T10:00:00\t100\t5\t20\t0\t0\n' >  "$CLAUDE_TIMESTAMP_HISTORY"
printf 'broken\n'                                 >> "$CLAUDE_TIMESTAMP_HISTORY"
out="$(bash "$SCRIPTS/setup.sh" --stats 2>&1)"
contains "stats: reports the damaged row"    "1 unreadable" "$out"
contains "stats: still totals the good ones" "sessions        1" "$out"

# A file with rows but none of them readable was unreachable before this
# task; the early return must land before the heading, not after it.
fresh 'HISTORY=on'
printf 'broken\nalso broken\n' > "$CLAUDE_TIMESTAMP_HISTORY"
out="$(bash "$SCRIPTS/setup.sh" --stats 2>&1)"
contains "stats: an all-damaged file says so"      "No readable sessions" "$out"
contains "stats: and counts what it could not read" "2 unreadable"        "$out"
lacks    "stats: no totals are printed for nothing" "sessions        "    "$out"

# A history whose longest session is zero seconds never satisfied
# `$2 + 0 > maxd + 0`, so awk's maxwhen stayed unset, its %s printed nothing,
# and the output line came back one field short. Every field after it shifted
# left: maxturns became a date, last became "0", and bad came back empty, which
# put a raw `[: : integer expression expected` in front of the user.
fresh 'HISTORY=on'
printf '2026-09-03T07:58:15\t0\t1\t0\t0\t0\n' > "$CLAUDE_TIMESTAMP_HISTORY"
out="$(bash "$SCRIPTS/setup.sh" --stats 2>&1)"
lacks    "stats: a zero-length session prints no shell error" "integer expression" "$out"
contains "stats: and is still counted"                        "sessions        1" "$out"
contains "stats: and its longest line reads as a duration"    "longest         2026-09-03  0s over 1 turns" "$out"

# The same field shift by the other route: a row can carry its six fields and
# still have an empty date, which the NF check passes and an empty %s then
# turns into two spaces where the reader expects one. The seeding was empty in
# the same way, so a maximum that carried no date was re-seeded by every later
# row and the last duration was reported as the longest.
fresh 'HISTORY=on'
printf '\t100\t2\t10\t5\t0\n' >  "$CLAUDE_TIMESTAMP_HISTORY"
printf '\t50\t1\t5\t2\t0\n'   >> "$CLAUDE_TIMESTAMP_HISTORY"
out="$(bash "$SCRIPTS/setup.sh" --stats 2>&1)"
lacks    "stats: an undated row prints no shell error"   "integer expression" "$out"
contains "stats: and both undated rows are counted"      "sessions        2"  "$out"
contains "stats: and the totals do not shift a column"   "turns           3"  "$out"
# The point of the seeding fix: 100 is the longest, not the 50 that came last.
contains "stats: and the longest is the longest, not the last" "1m40s" "$out"

# A dated row after an undated one must not become the "first" of the range,
# and the undated maximum must not be re-seeded by a shorter row behind it.
fresh 'HISTORY=on'
printf '\t100\t2\t10\t5\t0\n'                    >  "$CLAUDE_TIMESTAMP_HISTORY"
printf '2026-08-20T10:00:00\t50\t1\t5\t2\t0\n'   >> "$CLAUDE_TIMESTAMP_HISTORY"
out="$(bash "$SCRIPTS/setup.sh" --stats 2>&1)"
lacks    "stats: a mixed file prints no shell error"       "integer expression" "$out"
contains "stats: and still reports the true longest"       "1m40s"              "$out"
contains "stats: and counts both rows"                     "sessions        2"  "$out"

echo "stats reads a widened row"

sw() { bash "$SCRIPTS/setup.sh" --stats 2>&1; }

printf '2026-09-01T10:00:00\t3600\t10\t600\t0\t0\tone\tBash:100:5\n' \
  > "$CLAUDE_TIMESTAMP_HISTORY"
printf '2026-09-02T10:00:00\t1800\t5\t300\t0\t0\n' \
  >> "$CLAUDE_TIMESTAMP_HISTORY"
out="$(sw)"
contains "reader: counts both a widened and a plain row" "sessions        2" "$out"
refutes  "reader: and calls neither one damaged" grep -q "unreadable" <<< "$out"

printf '2026-09-01T10:00:00\t3600\t10\t600\t0\n' > "$CLAUDE_TIMESTAMP_HISTORY"
contains "reader: five fields is still damage" "unreadable" "$(sw)"

printf '2026-09-01T10:00:00\t3600\t10\t600\t0\t0\ta\tb\tc\n' > "$CLAUDE_TIMESTAMP_HISTORY"
contains "reader: nine fields is damage" "unreadable" "$(sw)"

printf '2026-09-01T10:00:00\t3600\tten\t600\t0\t0\n' > "$CLAUDE_TIMESTAMP_HISTORY"
contains "reader: a non-numeric timing field is damage the count alone missed" \
         "unreadable" "$(sw)"

bash "$SCRIPTS/setup.sh" --history=off --history-limit=50 >/dev/null
ct_load_config
is "--history is accepted"       "off" "$CT_HISTORY"
is "--history-limit is accepted" "50"  "$CT_HISTORY_LIMIT"

# write_config's account-level heredoc used to be hand-written with no line
# for PROJECTS, so this flag parsed, validated and reported success while
# writing nothing. Round-tripped through a real write and a real reload,
# rather than just checking the flag is accepted, because the flag path
# accepting a value was never the part that was broken.
bash "$SCRIPTS/setup.sh" --projects=on >/dev/null
ct_load_config
is "--projects is persisted by the account-level writer" "on" "$CT_PROJECTS"

refutes "a non on/off history is refused" bash "$SCRIPTS/setup.sh" --history=sometimes
refutes "a non-numeric limit is refused"  bash "$SCRIPTS/setup.sh" --history-limit=lots

# 0 reads as "none" by analogy with SLOW_AFTER and IDLE_AFTER, and means one.
refutes "history limit: 0 is refused" ct_is_history_limit "0"
asserts "history limit: 1 is accepted" ct_is_history_limit "1"
asserts "history limit: 200 is accepted" ct_is_history_limit "200"
out="$( CLAUDE_TIMESTAMP_CONFIG="$WORK/hl.conf" \
        bash "$SCRIPTS/setup.sh" --history-limit=0 2>&1 )" && rc=0 || rc=$?
is "history limit: setup refuses 0" "2" "$rc"
contains "history limit: and points at the real off switch" "--history=off" "$out"

echo "stats sections"

{
  printf '2026-09-01T10:00:00\t3600\t10\t600\t0\t0\talpha\tBash:100:5\n'
  printf '2026-09-02T10:00:00\t1800\t5\t300\t0\t0\talpha\tBash:50:3,Read:10:9\n'
  printf '2026-09-03T10:00:00\t900\t2\t100\t0\t0\tbeta\tRead:5:2\n'
} > "$CLAUDE_TIMESTAMP_HISTORY"
out="$(bash "$SCRIPTS/setup.sh" --stats 2>&1)"
contains "sections: a by-project block appears"      "by project" "$out"
contains "sections: the busiest project leads"       "alpha" "$out"
contains "sections: with its total and its count"    "1h30m" "$out"
contains "sections: a slowest-tools block appears"   "slowest tools" "$out"
contains "sections: summing a tool across sessions"  "2m30s" "$out"
contains "sections: and its call count"              "8 calls" "$out"

# (unnamed) only belongs to a mixed history: one row names a project, another
# sits beside it with "-" because it predates PROJECTS or found no name. Both
# must show up in the same table.
{
  printf '2026-09-01T10:00:00\t3600\t10\t600\t0\t0\talpha\tBash:100:5\n'
  printf '2026-09-02T10:00:00\t1800\t5\t300\t0\t0\t-\tBash:50:3\n'
} > "$CLAUDE_TIMESTAMP_HISTORY"
out="$(bash "$SCRIPTS/setup.sh" --stats 2>&1)"
contains "sections: a dash renders as unnamed" "(unnamed)" "$out"
contains "sections: beside the real project name it sat next to" "alpha" "$out"

printf '2026-09-01T10:00:00\t3600\t10\t600\t0\t0\n' > "$CLAUDE_TIMESTAMP_HISTORY"
out="$(bash "$SCRIPTS/setup.sh" --stats 2>&1)"
refutes "sections: no project data means no by-project block" \
        grep -q "by project" <<< "$out"
refutes "sections: no tool data means no slowest-tools block" \
        grep -q "slowest tools" <<< "$out"

# A history where every row carries "-" -- TOOL_TIMING=on but PROJECTS never
# turned on, so field 7 holds only a placeholder for field 8 -- must not draw
# a by-project block of one restated total. The slowest-tools block, which
# depends only on field 8, is unaffected and must still appear: the two
# sections are independent of each other.
printf '2026-09-01T10:00:00\t3600\t10\t600\t0\t0\t-\tBash:100:5\n' \
  > "$CLAUDE_TIMESTAMP_HISTORY"
out="$(bash "$SCRIPTS/setup.sh" --stats 2>&1)"
refutes "sections: an all-dashes history means no by-project block" \
        grep -q "by project" <<< "$out"
contains "sections: but the slowest-tools block still appears" \
         "slowest tools" "$out"

# A damaged entry inside field 8 costs its own tools and nothing else. The
# row's timings are intact and must still be counted.
printf '2026-09-01T10:00:00\t3600\t10\t600\t0\t0\talpha\tBash:100:5,broken,Read:x:y\n' \
  > "$CLAUDE_TIMESTAMP_HISTORY"
out="$(bash "$SCRIPTS/setup.sh" --stats 2>&1)"
contains "sections: a damaged tool entry leaves the row counted" "sessions        1" "$out"
refutes  "sections: and does not mark the row unreadable" grep -q "unreadable" <<< "$out"
contains "sections: the usable tool entry survives"       "1m40s" "$out"
refutes  "sections: the damaged ones do not appear"       grep -q "broken" <<< "$out"

# A row with a 9th field is damaged by the shared validity guard -- reported
# as unreadable by the totals above -- and must be excluded by BOTH
# breakdowns below it, not just the by-project one. The slowest-tools pass
# had its own upper bound missing, which let a malformed row's tool data
# leak into that table while the same row was being counted as unreadable.
{
  printf '2026-09-01T10:00:00\t3600\t10\t600\t0\t0\tgamma\tWrite:20:2\n'
  printf '2026-09-02T10:00:00\t1800\t5\t300\t0\t0\tdelta\tEdit:30:4\textra\n'
} > "$CLAUDE_TIMESTAMP_HISTORY"
out="$(bash "$SCRIPTS/setup.sh" --stats 2>&1)"
contains "sections: an over-long row is counted as unreadable" "1 unreadable" "$out"
contains "sections: the well-formed row's project still appears" "gamma" "$out"
refutes  "sections: the over-long row's project does not appear" grep -q "delta" <<< "$out"
contains "sections: the well-formed row's tool still appears" "Write" "$out"
refutes  "sections: the over-long row's tool does not appear" grep -q "Edit" <<< "$out"

# `--stats`'s slowest-tools pass ends its awk with `sort -rn | head -10`. A
# history with enough distinct tool names makes `head -10` close the pipe on
# `sort` before `sort` is done writing, sending it SIGPIPE; under this
# script's own errexit/pipefail that used to abort the whole report right
# there, silently truncating it with no error message and no slowest-tools
# table. 2000 distinct tools is enough to reproduce it -- the same volume the
# session-end.sh regression below uses for the same-shaped bug.
awk 'BEGIN {
  for (i = 0; i < 2000; i++)
    printf "2026-01-01T10:00:00\t100\t1\t10\t0\t0\talpha\tTool%04d:%d:1\n", i, 2000 - i
}' > "$CLAUDE_TIMESTAMP_HISTORY"
out="$(bash "$SCRIPTS/setup.sh" --stats 2>&1)" && big_stats_rc=0 || big_stats_rc=$?
is       "sections: a history with 2000 distinct tools still exits 0" \
         "0" "$big_stats_rc"
contains "sections: and the slowest-tools table still appears" \
         "slowest tools" "$out"
contains "sections: with the actual busiest tool named" "Tool0000" "$out"
contains "sections: and its correct summed duration" "33m20s" "$out"
contains "sections: and its correct call count" "(1 call)" "$out"

echo "stats filters"

{
  printf '2026-08-01T10:00:00\t3600\t10\t600\t0\t0\talpha\n'
  printf '2026-09-02T10:00:00\t1800\t5\t300\t0\t0\tbeta\n'
} > "$CLAUDE_TIMESTAMP_HISTORY"

out="$(bash "$SCRIPTS/setup.sh" --stats --since=2026-09-01 2>&1)"
contains "filters: since narrows the count"  "sessions        1" "$out"
contains "filters: and says so in the header" "since 2026-09-01" "$out"

out="$(bash "$SCRIPTS/setup.sh" --stats --project=alpha 2>&1)"
contains "filters: project narrows the count" "sessions        1" "$out"
contains "filters: and says which"            "alpha" "$out"

out="$(bash "$SCRIPTS/setup.sh" --stats --project=nope 2>&1)"
contains "filters: an unmatched project says so"      "No sessions match in nope" "$out"
contains "filters: and names the ones that do exist"  "alpha" "$out"

out="$(bash "$SCRIPTS/setup.sh" --stats --since=soon 2>&1)"
contains "filters: an unparseable since is refused"   "--since takes" "$out"
refutes  "filters: and is not silently ignored" \
         bash "$SCRIPTS/setup.sh" --stats --since=soon

is "filters: days ago renders ten digits" "10" \
   "$(ct_date_days_ago 7 | tr -d '\n' | wc -c | tr -d ' ')"

# The relative form end to end, not just the helper underneath it. The fixture
# rows carry fixed dates while "now" moves, so asserting which of them survive
# a seven-day window would start failing on its own. What is stable is that the
# form is accepted and resolves to a cutoff that gets named either way, which
# is why the unmatched branch names its filter too.
out="$(bash "$SCRIPTS/setup.sh" --stats --since=7d 2>&1)"
asserts  "filters: the relative form is accepted" \
         bash "$SCRIPTS/setup.sh" --stats --since=7d
contains "filters: and resolves to a dated cutoff" \
         "since $(ct_date_days_ago 7)" "$out"

# A leading zero must be read as decimal, not as octal by the shell
# arithmetic that multiplies it by 86400. "01d" through "07d" happen to be
# valid octal and so worked by accident; "08d" and "09d" are not valid octal
# and used to abort with a raw shell error instead of resolving a cutoff.
out="$(bash "$SCRIPTS/setup.sh" --stats --since=08d 2>&1)"
asserts  "filters: a leading-zero relative form is accepted (08d)" \
         bash "$SCRIPTS/setup.sh" --stats --since=08d
contains "filters: 08d resolves to a dated cutoff, not an octal error" \
         "since $(ct_date_days_ago 8)" "$out"
refutes  "filters: 08d does not surface a shell arithmetic error" \
         grep -q "value too great for base" <<< "$out"

out="$(bash "$SCRIPTS/setup.sh" --stats --since=09d 2>&1)"
asserts  "filters: a leading-zero relative form is accepted (09d)" \
         bash "$SCRIPTS/setup.sh" --stats --since=09d
contains "filters: 09d resolves to a dated cutoff, not an octal error" \
         "since $(ct_date_days_ago 9)" "$out"

# The relative form has to resolve in the CONFIGURED zone, not the machine's:
# the parser that reads --since=Nd runs before ct_load_config, so a cutoff
# computed right there would be rendered in whichever zone the machine
# happens to sit in. Every other assertion in this file leaves TZ unset, so
# machine and configured zone silently coincide and would never catch that.
# Pacific/Kiritimati (UTC+14) and Etc/GMT+12 (UTC-12) are 26 hours apart, more
# than a full day, so at least one of them is always on a different calendar
# date than any machine zone right now. Picked dynamically -- rather than
# hardcoding one -- so this cannot start silently asserting nothing the day
# somebody runs the suite from a machine that already sits in the zone
# chosen here.
if ct_tz_supported; then
  ct_machine_date="$(date +%Y-%m-%d)"
  ct_kiri_date="$(TZ=Pacific/Kiritimati date +%Y-%m-%d)"
  if [ "$ct_kiri_date" != "$ct_machine_date" ]; then
    ct_pinned_zone="Pacific/Kiritimati"; ct_pinned_date="$ct_kiri_date"
  else
    ct_pinned_zone="Etc/GMT+12"; ct_pinned_date="$(TZ=Etc/GMT+12 date +%Y-%m-%d)"
  fi

  fresh "TZ=$ct_pinned_zone" 'HISTORY=on'
  printf '%sT10:00:00\t3600\t10\t600\t0\t0\n' "$ct_pinned_date" > "$CLAUDE_TIMESTAMP_HISTORY"
  out="$(bash "$SCRIPTS/setup.sh" --stats --since=0d 2>&1)"
  contains "filters: the relative form resolves in the configured zone, not the machine's" \
           "since $ct_pinned_date" "$out"
  fresh 'HISTORY=on'
else
  skip "filters: the relative form resolves in the configured zone, not the machine's" \
       "no timezone database"
fi

echo
echo "project configuration"

PROJ="$WORK/projects"
rm -rf "$PROJ"
mkdir -p "$PROJ/home/.claude" "$PROJ/repo/.claude" "$PROJ/repo/src/deep" "$PROJ/plain"
printf 'TZ=UTC\nCOLOR=dim\nDISPLAY_FORMAT=24h\n' > "$PROJ/home/.claude/claude-timestamp.conf"
printf 'COLOR=cyan\n' > "$PROJ/repo/.claude/claude-timestamp.conf"

# ct_find_project_config and the layering are exercised in a subshell so the
# HOME and CLAUDE_TIMESTAMP_CONFIG they need cannot leak into later cases.
layered() {
  ( unset CLAUDE_TIMESTAMP_CONFIG
    HOME="$PROJ/home"
    ct_load_config "$1"
    printf '%s %s %s' "$CT_COLOR" "$CT_DISPLAY_FORMAT" "${CT_PROJECT_CONFIG:+found}" )
}

is "the project layer overrides only what it names" "cyan 24h found" "$(layered "$PROJ/repo")"
is "the search walks up from a subdirectory"        "cyan 24h found" "$(layered "$PROJ/repo/src/deep")"
is "a directory with no project config uses yours"  "dim 24h "      "$(layered "$PROJ/plain")"
is "the search stops at home"                       "dim 24h "      "$(layered "$PROJ/home")"

# $HOME can be a symlink -- an automounted home, macOS, a container -- and a
# directory reached by its real path then never matches $HOME as written. The
# stop at home has to survive that. Without it the account config is picked up
# as a project layer: the settings still resolve, because it is the same file
# read twice, but --doctor, --show and /timestamps all then report a project
# file that does not exist, and the slash command is told to say a project
# pins the setting and is usually committed and shared.
# write_project_config already resolves both sides for exactly this reason.
#
# Git Bash creates a copy rather than a link unless Windows is in developer
# mode, and a copied home is a different directory that the stop is right to
# walk past. The premise cannot be staged there, so the pair skips rather than
# asserting something the platform never set up.
mkdir -p "$PROJ/home/inside"
ln -sfn "$PROJ/home" "$PROJ/homelink" 2>/dev/null
linked() {
  ( unset CLAUDE_TIMESTAMP_CONFIG
    HOME="$PROJ/homelink"
    ct_load_config "$1"
    printf '%s' "${CT_PROJECT_CONFIG:+found}" )
}
if [ -L "$PROJ/homelink" ]; then
  is "the search stops at a symlinked home"                "" "$(linked "$PROJ/home")"
  is "and does not treat the account config as a project"  "" "$(linked "$PROJ/home/inside")"
else
  skip "the search stops at a symlinked home" \
       "ln -s did not produce a link on this filesystem"
  skip "and does not treat the account config as a project" \
       "ln -s did not produce a link on this filesystem"
fi

refutes "no project config is reported as not found" ct_find_project_config "$PROJ/plain"
refutes "a missing directory is not searched"        ct_find_project_config "$PROJ/nowhere"
refutes "an empty directory argument finds nothing"  ct_find_project_config ""

# Giving up at the 40-level cap and genuinely finding nothing look identical
# to a caller unless something records which one happened.
# CT_PROJECT_SEARCH_CAPPED is that record.
DEEP="$PROJ/deep"
rm -rf "$DEEP"
d="$DEEP"
i=0
while [ "$i" -lt 45 ]; do
  d="$d/lvl$i"
  i=$((i + 1))
done
mkdir -p "$d"

capped() {
  ( unset CLAUDE_TIMESTAMP_CONFIG
    HOME="$PROJ/nonexistent-home"
    ct_find_project_config "$1" >/dev/null 2>&1
    printf '%s' "${CT_PROJECT_SEARCH_CAPPED:-}" )
}
is "the search flags a walk that hit the cap"    "1" "$(capped "$d")"
is "a found config leaves the cap flag unset"    ""  "$(capped "$PROJ/repo")"
is "nothing found short of the cap leaves it unset" "" "$(capped "$PROJ/plain")"

# CLAUDE_TIMESTAMP_CONFIG names one exact file, so it must not pick up a
# project layer as well. The rest of this suite depends on that.
out="$( cd "$PROJ/repo" && CLAUDE_TIMESTAMP_CONFIG="$PROJ/home/.claude/claude-timestamp.conf" \
        HOME="$PROJ/home" bash -c "source '$ROOT/hooks/scripts/lib/config.sh'; ct_load_config; printf '%s' \"\$CT_COLOR\"" )"
is "an explicit config file ignores the project layer" "dim" "$out"

if command -v jq >/dev/null 2>&1; then
  hook_in() {
    # $1 = cwd reported in the payload, $2 = extra payload fields
    ( unset CLAUDE_TIMESTAMP_CONFIG
      HOME="$PROJ/home"
      printf '{"session_id":"proj","index":0,"delta":"x","cwd":"%s"%s}' "$1" "$2" \
        | bash "$SCRIPTS/message-display.sh" | jq -r '.hookSpecificOutput.displayContent' )
  }
  printf 'COLOR=none\nELAPSED=off\nIDLE_AFTER=0\nDATE_ROLLOVER=off\nDISPLAY_FORMAT=iso\n' \
    > "$PROJ/repo/.claude/claude-timestamp.conf"

  contains "a hook honours the project config for its cwd" "T" "$(hook_in "$PROJ/repo/src/deep" "")"
  lacks "a hook outside the project does not" "T" "$(strip_ansi "$(hook_in "$PROJ/plain" "")")"

  # Regression: the payload fields were split on tab, but tab is IFS
  # whitespace, so bash collapsed the empty agent_id and shifted cwd into its
  # place. Any payload carrying an agent_id would have worked while every
  # payload without one silently lost its project config.
  contains "cwd survives an absent agent_id" "T" "$(hook_in "$PROJ/repo" "")"
  contains "cwd survives a present agent_id" "T" "$(hook_in "$PROJ/repo" ',"agent_id":"sub-1"')"

  mkdir -p "$PROJ/with space/.claude"
  printf 'DISPLAY_FORMAT=iso\nCOLOR=none\nELAPSED=off\nIDLE_AFTER=0\nDATE_ROLLOVER=off\n' \
    > "$PROJ/with space/.claude/claude-timestamp.conf"
  contains "a cwd containing spaces is handled" "T" "$(hook_in "$PROJ/with space" "")"

  # The tool hook decides whether to act before parsing its payload, so it has
  # no cwd of its own to resolve a project config from and used $PWD instead.
  # The marker hook uses the payload's cwd. When they disagree, the marker
  # believes attribution is available and the writer never fills the log.
  PT="$WORK/tooltiming"
  rm -rf "$PT"; mkdir -p "$PT/home/.claude" "$PT/repo/.claude"
  printf 'TOOL_TIMING=off\n' > "$PT/home/.claude/claude-timestamp.conf"
  printf 'TOOL_TIMING=on\n'  > "$PT/repo/.claude/claude-timestamp.conf"

  out="$( unset CLAUDE_TIMESTAMP_CONFIG
          HOME="$PT/home"; export HOME
          cd "$PT/home" || exit 1
          printf '{"session_id":"tt","cwd":"%s/repo"}' "$PT" \
            | bash "$SCRIPTS/user-prompt-submit.sh" >/dev/null
          printf '{"session_id":"tt","tool_name":"Bash","hook_event_name":"PostToolUse","duration_ms":1500}' \
            | bash "$SCRIPTS/post-tool-use.sh" >/dev/null
          cat "$(ct_state_file tt).tools" 2>/dev/null )"
  contains "tool timing: follows the payload's project, not the process's cwd" "Bash 1.500 ok" "$out"

  # The legacy fallback scan looks for a session with no staged flag. It
  # matched the WHOLE PATH against *.*, so any TMPDIR with a dot in it -- macOS
  # hands out /var/folders/xy/....../T -- made every entry look like a dotted
  # sidecar file, the scan found no sessions, and tool timing silently never
  # turned on for a session that predates the flag.
  DT="$WORK/dotted.v1.2"
  rm -rf "$DT"; mkdir -p "$DT/home/.claude" "$DT/tmp"
  printf 'TOOL_TIMING=on\n' > "$DT/home/.claude/claude-timestamp.conf"
  out="$( unset CLAUDE_TIMESTAMP_CONFIG
          HOME="$DT/home"; export HOME
          TMPDIR="$DT/tmp"; export TMPDIR
          dotdir="$TMPDIR/claude-timestamp-$(id -u)"
          mkdir -p "$dotdir"; printf '%s' "$(date +%s)" > "$dotdir/legacy"
          printf '{"session_id":"legacy","tool_name":"Bash","hook_event_name":"PostToolUse","duration_ms":1500}' \
            | bash "$SCRIPTS/post-tool-use.sh" >/dev/null 2>&1
          cat "$dotdir/legacy.tools" 2>/dev/null )"
  contains "tool timing: the legacy scan survives a dot in TMPDIR" "Bash 1.500 ok" "$out"
fi

echo
echo "writing a project config"

rm -rf "$PROJ/writable"; mkdir -p "$PROJ/writable"
( cd "$PROJ/writable" && unset CLAUDE_TIMESTAMP_CONFIG && HOME="$PROJ/home" \
    bash "$SCRIPTS/setup.sh" --project --color=cyan >/dev/null 2>&1 )
written="$PROJ/writable/.claude/claude-timestamp.conf"
asserts "--project creates the file" test -r "$written"
is "--project writes what was named" "1" "$(grep -c '^COLOR=cyan' "$written")"
is "--project writes nothing else"   "0" "$(grep -c '^DISPLAY_FORMAT=' "$written")"

( cd "$PROJ/writable" && unset CLAUDE_TIMESTAMP_CONFIG && HOME="$PROJ/home" \
    bash "$SCRIPTS/setup.sh" --project --display=short >/dev/null 2>&1 )
is "--project keeps what was already pinned" "1" "$(grep -c '^COLOR=cyan' "$written")"
is "--project adds the new setting"          "1" "$(grep -c '^DISPLAY_FORMAT=short' "$written")"

# The project writer reads the file it is about to replace, so it has the same
# truncate-in-place hazard as the account writer, and a project config is read
# by a hook on every message of every session in that repository.
exec 9< "$written"
( cd "$PROJ/writable" && unset CLAUDE_TIMESTAMP_CONFIG && HOME="$PROJ/home" \
    bash "$SCRIPTS/setup.sh" --project --color=green >/dev/null 2>&1 )
opened_project="$(cat <&9)"
exec 9<&-
contains "--project never truncates a file already being read" "COLOR=cyan" "$opened_project"
is "--project still applied the new value" "1" "$(grep -c '^COLOR=green' "$written")"

# The marker and its part colours must be wired into the project writer the
# same way every other setting is, or --project silently drops them: the
# command exits 0, claims nothing, and the repository's pinned marker never
# lands anywhere.
rm -rf "$PROJ/writable-marker"; mkdir -p "$PROJ/writable-marker"
( cd "$PROJ/writable-marker" && unset CLAUDE_TIMESTAMP_CONFIG && HOME="$PROJ/home" \
    bash "$SCRIPTS/setup.sh" --project --marker='%time' >/dev/null 2>&1 )
written_marker="$PROJ/writable-marker/.claude/claude-timestamp.conf"
is "--project writes the marker"      "1" "$(grep -c '^MARKER=%time$' "$written_marker")"
is "--project writes only the marker" "1" "$(grep -c '^[A-Z_]*=' "$written_marker")"
marker_read_back="$(
  unset CLAUDE_TIMESTAMP_CONFIG
  HOME="$PROJ/home"
  ct_load_config "$PROJ/writable-marker"
  printf '%s' "$CT_MARKER_TEMPLATE"
)"
is "a project marker is read back by the loader" "%time" "$marker_read_back"

# write_project_config has the same unquoted-value defect write_config has: a
# marker's leading or trailing space is meaningful, and used to come back
# shorter than it went in through this writer too.
rm -rf "$PROJ/writable-markerspace"; mkdir -p "$PROJ/writable-markerspace"
( cd "$PROJ/writable-markerspace" && unset CLAUDE_TIMESTAMP_CONFIG && HOME="$PROJ/home" \
    bash "$SCRIPTS/setup.sh" --project --marker='%time ' >/dev/null 2>&1 )
written_markerspace="$PROJ/writable-markerspace/.claude/claude-timestamp.conf"
is "--project writes a trailing-space marker quoted" "1" \
  "$(grep -c "^MARKER='%time '\$" "$written_markerspace")"
markerspace_read_back="$(
  unset CLAUDE_TIMESTAMP_CONFIG
  HOME="$PROJ/home"
  ct_load_config "$PROJ/writable-markerspace"
  printf '%s' "$CT_MARKER_TEMPLATE"
)"
is "a project marker's trailing space survives the round trip" "%time " "$markerspace_read_back"

# write_project_config carries an unnamed key forward as raw text lifted out
# of the existing file with sed -- already serialised, quotes and all. Running
# conf_value over that carried text a second time wraps it again, and the next
# unrelated write wraps it a third: two chained writes that never name MARKER
# again must not compound the quoting on a value this run did not touch.
rm -rf "$PROJ/writable-markerchain"; mkdir -p "$PROJ/writable-markerchain"
( cd "$PROJ/writable-markerchain" && unset CLAUDE_TIMESTAMP_CONFIG && HOME="$PROJ/home" \
    bash "$SCRIPTS/setup.sh" --project --marker='%time ' >/dev/null 2>&1 )
( cd "$PROJ/writable-markerchain" && unset CLAUDE_TIMESTAMP_CONFIG && HOME="$PROJ/home" \
    bash "$SCRIPTS/setup.sh" --project --time-color=cyan >/dev/null 2>&1 )
( cd "$PROJ/writable-markerchain" && unset CLAUDE_TIMESTAMP_CONFIG && HOME="$PROJ/home" \
    bash "$SCRIPTS/setup.sh" --project --elapsed-color=green >/dev/null 2>&1 )
written_markerchain="$PROJ/writable-markerchain/.claude/claude-timestamp.conf"
is "a carried marker is not re-quoted across chained writes" "1" \
  "$(grep -c "^MARKER='%time '\$" "$written_markerchain")"
markerchain_read_back="$(
  unset CLAUDE_TIMESTAMP_CONFIG
  HOME="$PROJ/home"
  ct_load_config "$PROJ/writable-markerchain"
  printf '%s' "$CT_MARKER_TEMPLATE"
)"
is "a carried marker's trailing space still survives three chained writes" "%time " "$markerchain_read_back"

rm -rf "$PROJ/writable-timecolor"; mkdir -p "$PROJ/writable-timecolor"
( cd "$PROJ/writable-timecolor" && unset CLAUDE_TIMESTAMP_CONFIG && HOME="$PROJ/home" \
    bash "$SCRIPTS/setup.sh" --project --time-color=cyan >/dev/null 2>&1 )
written_timecolor="$PROJ/writable-timecolor/.claude/claude-timestamp.conf"
is "--project writes the time colour"      "1" "$(grep -c '^TIME_COLOR=cyan$' "$written_timecolor")"
is "--project writes only the time colour" "1" "$(grep -c '^[A-Z_]*=' "$written_timecolor")"
timecolor_read_back="$(
  unset CLAUDE_TIMESTAMP_CONFIG
  HOME="$PROJ/home"
  ct_load_config "$PROJ/writable-timecolor"
  printf '%s' "$CT_TIME_COLOR"
)"
is "a project time colour is read back by the loader" "cyan" "$timecolor_read_back"

( cd "$PROJ/writable-timecolor" && unset CLAUDE_TIMESTAMP_CONFIG && HOME="$PROJ/home" \
    bash "$SCRIPTS/setup.sh" --project --time-color=inherit >/dev/null 2>&1 )
is "--project --time-color=inherit clears the pinned colour" "1" "$(grep -c '^TIME_COLOR=$' "$written_timecolor")"

# HISTORY and HISTORY_LIMIT were missing from write_project_config's own
# positional list, so they were not merely un-writable through --project but
# silently erased from a project config that already pinned them: an unrelated
# write destroyed settings the user pinned by hand.
rm -rf "$PROJ/writable-history"; mkdir -p "$PROJ/writable-history/.claude"
printf 'HISTORY=off\nHISTORY_LIMIT=10\nCOLOR=cyan\nMARKER=%%time\n' \
  > "$PROJ/writable-history/.claude/claude-timestamp.conf"
( cd "$PROJ/writable-history" && unset CLAUDE_TIMESTAMP_CONFIG && HOME="$PROJ/home" \
    bash "$SCRIPTS/setup.sh" --project --tz=UTC >/dev/null 2>&1 )
written_history="$PROJ/writable-history/.claude/claude-timestamp.conf"
is "an unrelated --project write keeps a pinned HISTORY"       "1" "$(grep -c '^HISTORY=off$' "$written_history")"
is "an unrelated --project write keeps a pinned HISTORY_LIMIT" "1" "$(grep -c '^HISTORY_LIMIT=10$' "$written_history")"
is "an unrelated --project write keeps the rest too"           "1" "$(grep -c '^COLOR=cyan$' "$written_history")"

# write_project_config's extraction of an already-pinned value cannot tell
# "key absent" from "key present but empty" -- both come back "" from the
# sed -n "s/^KEY=//p" it uses -- so a key deliberately pinned to empty (TZ=,
# meaning machine local time; a part colour set to inherit) used to be
# dropped by the next unrelated write. TZ=local is exactly that: an empty
# TZ= line, not a missing one.
rm -rf "$PROJ/writable-tzlocal"; mkdir -p "$PROJ/writable-tzlocal"
( cd "$PROJ/writable-tzlocal" && unset CLAUDE_TIMESTAMP_CONFIG && HOME="$PROJ/home" \
    bash "$SCRIPTS/setup.sh" --project --tz=local >/dev/null 2>&1 )
written_tzlocal="$PROJ/writable-tzlocal/.claude/claude-timestamp.conf"
is "--project --tz=local pins an empty TZ" "1" "$(grep -c '^TZ=$' "$written_tzlocal")"
( cd "$PROJ/writable-tzlocal" && unset CLAUDE_TIMESTAMP_CONFIG && HOME="$PROJ/home" \
    bash "$SCRIPTS/setup.sh" --project --color=none >/dev/null 2>&1 )
is "an unrelated --project write keeps a pinned TZ=local" "1" "$(grep -c '^TZ=$' "$written_tzlocal")"
is "and still writes the unrelated setting"               "1" "$(grep -c '^COLOR=none$' "$written_tzlocal")"

rm -rf "$PROJ/writable-tcinherit"; mkdir -p "$PROJ/writable-tcinherit"
( cd "$PROJ/writable-tcinherit" && unset CLAUDE_TIMESTAMP_CONFIG && HOME="$PROJ/home" \
    bash "$SCRIPTS/setup.sh" --project --time-color=cyan >/dev/null 2>&1 )
( cd "$PROJ/writable-tcinherit" && unset CLAUDE_TIMESTAMP_CONFIG && HOME="$PROJ/home" \
    bash "$SCRIPTS/setup.sh" --project --time-color=inherit >/dev/null 2>&1 )
written_tcinherit="$PROJ/writable-tcinherit/.claude/claude-timestamp.conf"
is "--project --time-color=inherit pins an empty TIME_COLOR" "1" "$(grep -c '^TIME_COLOR=$' "$written_tcinherit")"
( cd "$PROJ/writable-tcinherit" && unset CLAUDE_TIMESTAMP_CONFIG && HOME="$PROJ/home" \
    bash "$SCRIPTS/setup.sh" --project --subagents=off >/dev/null 2>&1 )
is "an unrelated --project write keeps a pinned inherited TIME_COLOR" "1" \
  "$(grep -c '^TIME_COLOR=$' "$written_tcinherit")"
is "and still writes the unrelated setting"                          "1" \
  "$(grep -c '^SUBAGENTS=off$' "$written_tcinherit")"

# MARKER has no alias word for "empty" the way TZ has "local" and the part
# colours have "inherit" -- the empty string itself is the legal value -- so
# write_project_config needs the caller to say "named" separately (see
# marker_named) rather than reading it off the value. Otherwise --project
# --marker= would report success and leave a previously pinned template
# untouched, the same silent no-op Finding B closed outside --project.
rm -rf "$PROJ/writable-markerempty"; mkdir -p "$PROJ/writable-markerempty"
( cd "$PROJ/writable-markerempty" && unset CLAUDE_TIMESTAMP_CONFIG && HOME="$PROJ/home" \
    bash "$SCRIPTS/setup.sh" --project --marker='%time' >/dev/null 2>&1 )
( cd "$PROJ/writable-markerempty" && unset CLAUDE_TIMESTAMP_CONFIG && HOME="$PROJ/home" \
    bash "$SCRIPTS/setup.sh" --project --marker= >/dev/null 2>&1 )
written_markerempty="$PROJ/writable-markerempty/.claude/claude-timestamp.conf"
is "--project --marker= overwrites a pinned template with empty" "1" \
  "$(grep -c '^MARKER=$' "$written_markerempty")"

# An unknown key -- one a newer version of the plugin wrote -- must survive
# an unrelated --project write from this (older) setup.sh, per the promise
# in lib/config.sh that a config a newer version writes stays readable by an
# older one. Planted directly: this version's setup.sh has no flag that
# would write such a key itself.
rm -rf "$PROJ/writable-unknown"; mkdir -p "$PROJ/writable-unknown/.claude"
printf 'COLOR=cyan\nSOME_FUTURE_KEY=surprise\n' \
  > "$PROJ/writable-unknown/.claude/claude-timestamp.conf"
( cd "$PROJ/writable-unknown" && unset CLAUDE_TIMESTAMP_CONFIG && HOME="$PROJ/home" \
    bash "$SCRIPTS/setup.sh" --project --tz=UTC >/dev/null 2>&1 )
written_unknown="$PROJ/writable-unknown/.claude/claude-timestamp.conf"
is "an unrelated --project write keeps an unknown key"      "1" "$(grep -c '^SOME_FUTURE_KEY=surprise$' "$written_unknown")"
is "an unrelated --project write still keeps the rest too"  "1" "$(grep -c '^COLOR=cyan$' "$written_unknown")"
is "an unrelated --project write still writes the new one"  "1" "$(grep -c '^TZ=UTC$' "$written_unknown")"

# A comment somebody wrote by hand must survive a rewrite, and a second
# rewrite must not duplicate the three header lines this function generates
# itself. Nothing above exercises the carry-over loop's comment handling: the
# home-directory refusal tests return before that loop ever runs. A single
# rewrite alone would also miss a duplication bug -- the header is only ever
# written once per call, so it takes a second call to see it accumulate.
rm -rf "$PROJ/writable-comment"; mkdir -p "$PROJ/writable-comment/.claude"
printf '# a hand-written note\nCOLOR=cyan\n' \
  > "$PROJ/writable-comment/.claude/claude-timestamp.conf"
( cd "$PROJ/writable-comment" && unset CLAUDE_TIMESTAMP_CONFIG && HOME="$PROJ/home" \
    bash "$SCRIPTS/setup.sh" --project --color=none >/dev/null 2>&1 )
written_comment="$PROJ/writable-comment/.claude/claude-timestamp.conf"
is "a hand-written comment survives a rewrite"    "1" "$(grep -c '^# a hand-written note$' "$written_comment")"
is "the unnamed pinned key is kept alongside it"  "1" "$(grep -c '^COLOR=none$' "$written_comment")"

( cd "$PROJ/writable-comment" && unset CLAUDE_TIMESTAMP_CONFIG && HOME="$PROJ/home" \
    bash "$SCRIPTS/setup.sh" --project --tz=UTC >/dev/null 2>&1 )
is "the generated header does not accumulate over a second rewrite" "1" \
   "$(grep -c '^# claude-timestamp settings for this project$' "$written_comment")"
is "the hand-written comment still appears exactly once"            "1" \
   "$(grep -c '^# a hand-written note$' "$written_comment")"

rm -rf "$PROJ/writable-historyflag"; mkdir -p "$PROJ/writable-historyflag"
( cd "$PROJ/writable-historyflag" && unset CLAUDE_TIMESTAMP_CONFIG && HOME="$PROJ/home" \
    bash "$SCRIPTS/setup.sh" --project --history=off >/dev/null 2>&1 )
written_historyflag="$PROJ/writable-historyflag/.claude/claude-timestamp.conf"
is "--project writes HISTORY"      "1" "$(grep -c '^HISTORY=off$' "$written_historyflag")"
is "--project writes only HISTORY" "1" "$(grep -c '^[A-Z_]*=' "$written_historyflag")"
historyflag_read_back="$(
  unset CLAUDE_TIMESTAMP_CONFIG
  HOME="$PROJ/home"
  ct_load_config "$PROJ/writable-historyflag"
  printf '%s' "$CT_HISTORY"
)"
is "a project HISTORY is read back by the loader" "off" "$historyflag_read_back"

rm -rf "$PROJ/writable-historylimit"; mkdir -p "$PROJ/writable-historylimit"
( cd "$PROJ/writable-historylimit" && unset CLAUDE_TIMESTAMP_CONFIG && HOME="$PROJ/home" \
    bash "$SCRIPTS/setup.sh" --project --history-limit=10 >/dev/null 2>&1 )
written_historylimit="$PROJ/writable-historylimit/.claude/claude-timestamp.conf"
is "--project writes HISTORY_LIMIT"      "1" "$(grep -c '^HISTORY_LIMIT=10$' "$written_historylimit")"
is "--project writes only HISTORY_LIMIT" "1" "$(grep -c '^[A-Z_]*=' "$written_historylimit")"
historylimit_read_back="$(
  unset CLAUDE_TIMESTAMP_CONFIG
  HOME="$PROJ/home"
  ct_load_config "$PROJ/writable-historylimit"
  printf '%s' "$CT_HISTORY_LIMIT"
)"
is "a project HISTORY_LIMIT is read back by the loader" "10" "$historylimit_read_back"

# In a directory that has pinned nothing yet, --project on its own has no
# settings to write and should say so rather than create an empty file. Exit
# code 1 specifically -- 2 is the home-directory refusal's code, and a
# regression that swapped them would otherwise pass a plain non-zero check.
mkdir -p "$PROJ/empty"
( cd "$PROJ/empty" && unset CLAUDE_TIMESTAMP_CONFIG && HOME="$PROJ/home" \
    bash "$SCRIPTS/setup.sh" --project >/dev/null 2>&1 )
is "--project with nothing to write is refused" "1" "$?"
if [ -e "$PROJ/empty/.claude/claude-timestamp.conf" ]; then
  fail "a refused write leaves no file behind" "no file" "a file was created"
else
  pass "a refused write leaves no file behind"
fi

# --project writes $PWD/.claude/claude-timestamp.conf. From the home directory
# that is the account config, which ct_find_project_config explicitly refuses
# to treat as a project layer, so the two halves of the feature disagree about
# what the file is.
PH="$WORK/projhome"
rm -rf "$PH"; mkdir -p "$PH/.claude"
printf '# a hand-written note\nCOLOR=cyan\n' > "$PH/.claude/claude-timestamp.conf"
out="$( cd "$PH" && unset CLAUDE_TIMESTAMP_CONFIG
        HOME="$PH" bash "$SCRIPTS/setup.sh" --project --color=none 2>&1 )" && rc=0 || rc=$?
is "project: refused from the home directory" "2" "$rc"
contains "project: and says why" "your account" "$out"
contains "project: the file is untouched" "a hand-written note" \
         "$(cat "$PH/.claude/claude-timestamp.conf")"

# The refusal must compare resolved paths, not textual ones -- a symlinked
# home is the common case where $PWD and $HOME name the same directory
# without spelling it the same way.
if [ "$CT_HAS_SYMLINKS" = "1" ]; then
  PHREAL="$WORK/projhome-real"
  PHLINK="$WORK/projhome-link"
  rm -rf "$PHREAL" "$PHLINK"; mkdir -p "$PHREAL/.claude"
  ln -s "$PHREAL" "$PHLINK"
  printf '# a hand-written note\nCOLOR=cyan\n' > "$PHREAL/.claude/claude-timestamp.conf"
  out="$( cd "$PHLINK" && unset CLAUDE_TIMESTAMP_CONFIG
          HOME="$PHREAL" bash "$SCRIPTS/setup.sh" --project --color=none 2>&1 )" && rc=0 || rc=$?
  is "project: refused from a symlinked home too" "2" "$rc"
  contains "project: symlinked home says why" "your account" "$out"
else
  skip "project: refused from a symlinked home too" "needs real symlinks"
  skip "project: symlinked home says why" "needs real symlinks"
fi

out="$( cd "$PROJ/writable" && unset CLAUDE_TIMESTAMP_CONFIG && HOME="$PROJ/home" \
        bash "$SCRIPTS/setup.sh" --doctor 2>&1 )"
contains "doctor names the project file" "project file" "$out"
out="$( cd "$PROJ/plain" && unset CLAUDE_TIMESTAMP_CONFIG && HOME="$PROJ/home" \
        bash "$SCRIPTS/setup.sh" --doctor 2>&1 )"
contains "doctor says when there is no project file" "none for this directory" "$out"
lacks "doctor stays quiet about the cap when the search did not hit it" \
      "40 levels" "$out"

out="$( cd "$d" && unset CLAUDE_TIMESTAMP_CONFIG && HOME="$PROJ/nonexistent-home" \
        bash "$SCRIPTS/setup.sh" --doctor 2>&1 )"
contains "doctor names the cap when the search hit it" "stopped after 40 levels" "$out"

echo
echo "doctor"

fresh
out="$(bash "$SCRIPTS/setup.sh" --doctor)"
contains "doctor reports jq"           "jq" "$out"
contains "doctor reports the platform" "uname" "$out"
contains "doctor renders a preview"    "Preview" "$out"
contains "doctor reports no problems on a healthy setup" "No problems found" "$out"
asserts "doctor exits zero when healthy" bash "$SCRIPTS/setup.sh" --doctor

# Tool duration comes from the payload's duration_ms, never from EPOCHREALTIME,
# so the tool-timing line must not vary with it. `bash setup.sh --doctor`
# always starts a fresh bash 5 process here, which repopulates EPOCHREALTIME
# on its own no matter what the caller unset, so proving the line is
# EPOCHREALTIME-independent means unsetting it and then sourcing the script
# into the very same process rather than exec'ing a new one.
fresh "TOOL_TIMING=on"
out="$(bash -c 'unset EPOCHREALTIME; . "$1" --doctor' _ "$SCRIPTS/setup.sh" 2>&1)"
lacks "doctor's tool-timing line ignores EPOCHREALTIME" "whole seconds only" "$out"

fresh 'MARKER=%time' 'TIME_COLOR=cyan'
out="$(bash "$SCRIPTS/setup.sh" --doctor)"
contains "doctor: reports the template"     "%time" "$out"
contains "doctor: reports a part colour"    "cyan"  "$out"

echo
echo "facts file"

fresh
rm -f "$CLAUDE_TIMESTAMP_FACTS"
printf '{"session_id":"facts"}' | CLAUDE_CODE_ENTRYPOINT=cli bash "$SCRIPTS/session-start.sh" >/dev/null
asserts "facts: written at session start" test -r "$CLAUDE_TIMESTAMP_FACTS"
asserts "facts: valid json" jq -e . "$CLAUDE_TIMESTAMP_FACTS"
is "facts: shape is versioned" "2" "$(jq -r '.facts_version' "$CLAUDE_TIMESTAMP_FACTS")"
is "facts: reports jq present" "true" "$(jq -r '.clients.cli.jq' "$CLAUDE_TIMESTAMP_FACTS")"
is "facts: version matches version.txt" \
   "$(tr -d '[:space:]' < "$ROOT/version.txt")" \
   "$(jq -r '.clients.cli.version' "$CLAUDE_TIMESTAMP_FACTS")"
is "facts: state dir is writable here" "true" "$(jq -r '.clients.cli.state_dir_writable' "$CLAUDE_TIMESTAMP_FACTS")"
if ct_tz_supported; then
  is "facts: timezone database detected" "true" "$(jq -r '.clients.cli.tz_database' "$CLAUDE_TIMESTAMP_FACTS")"
else
  is "facts: timezone database absent" "false" "$(jq -r '.clients.cli.tz_database' "$CLAUDE_TIMESTAMP_FACTS")"
fi

# The whole point of the write time: a reader has to be able to tell this
# session's entry from one a terminal left behind weeks ago. Allow a couple of
# seconds of slack for a slow session start rather than pinning it exactly.
# `// 0` so a missing field fails this assertion rather than aborting the run
# under set -u and hiding every check after it.
age="$(( $(date +%s) - $(jq -r '.clients.cli.written_at // 0' "$CLAUDE_TIMESTAMP_FACTS") ))"
asserts "facts: carries a fresh write time" test "$age" -ge 0 -a "$age" -le 5

# /timestamps is asked to diagnose "no colour, not a terminal" from facts the
# hook actually writes, so the entrypoint it inherits from Claude Code has to
# be one of them, and it is the key rather than a field.
rm -f "$CLAUDE_TIMESTAMP_FACTS"
printf '{"session_id":"facts"}' | CLAUDE_CODE_ENTRYPOINT=claude-vscode bash "$SCRIPTS/session-start.sh" >/dev/null
asserts "facts: keyed by entrypoint" \
  jq -e '.clients | has("claude-vscode")' "$CLAUDE_TIMESTAMP_FACTS"

# An older Claude Code predates the variable, so there is no name to key on.
# It still needs an entry rather than being dropped on the floor.
rm -f "$CLAUDE_TIMESTAMP_FACTS"
printf '{"session_id":"facts"}' | env -u CLAUDE_CODE_ENTRYPOINT bash "$SCRIPTS/session-start.sh" >/dev/null
asserts "facts: an unnamed entrypoint is keyed as unknown" \
  jq -e '.clients | has("unknown")' "$CLAUDE_TIMESTAMP_FACTS"

# The reason the file is keyed at all: a terminal and a desktop session share
# one home directory on macOS, and reading the wrong client's entry is worse
# than reading none.
rm -f "$CLAUDE_TIMESTAMP_FACTS"
printf '{"session_id":"facts"}' | CLAUDE_CODE_ENTRYPOINT=cli bash "$SCRIPTS/session-start.sh" >/dev/null
printf '{"session_id":"facts"}' | CLAUDE_CODE_ENTRYPOINT=claude-desktop bash "$SCRIPTS/session-start.sh" >/dev/null
asserts "facts: a second client does not erase the first" \
  jq -e '(.clients | has("cli")) and (.clients | has("claude-desktop"))' "$CLAUDE_TIMESTAMP_FACTS"

# A stale file must be replaced rather than appended to or left alone.
printf 'not json at all' > "$CLAUDE_TIMESTAMP_FACTS"
printf '{"session_id":"facts"}' | bash "$SCRIPTS/session-start.sh" >/dev/null
asserts "facts: a stale file is replaced" jq -e . "$CLAUDE_TIMESTAMP_FACTS"

# A file whose entries were written to some other version of this shape must be
# dropped rather than carried across and relabelled as this one. Without the
# version check the entries would survive, wearing a facts_version that
# promises a shape they were never written to.
printf '{"facts_version":1,"clients":{"ancient":{"whatever":true}}}' > "$CLAUDE_TIMESTAMP_FACTS"
printf '{"session_id":"facts"}' | CLAUDE_CODE_ENTRYPOINT=cli bash "$SCRIPTS/session-start.sh" >/dev/null
refutes "facts: entries from another shape version are not carried over" \
  jq -e '.clients | has("ancient")' "$CLAUDE_TIMESTAMP_FACTS"

# Written by rename, so a concurrent reader cannot see a half-written file.
is "facts: no temp file left behind" "" "$(find "$WORK" -name 'facts.json.*' 2>/dev/null)"

# The absence of a temp file is necessary but not sufficient: a direct write
# also leaves none behind. Pin the actual claim -- the file is replaced by
# rename, not edited in place -- by checking the inode changes.
printf '{}' > "$CLAUDE_TIMESTAMP_FACTS"
# shellcheck disable=SC2012  # a fixed temp path, and `ls -i` is the only
# inode read that works on GNU, BSD and Git Bash alike.
before="$(ls -i "$CLAUDE_TIMESTAMP_FACTS" | awk '{print $1}')"
printf '{"session_id":"facts"}' | bash "$SCRIPTS/session-start.sh" >/dev/null
# shellcheck disable=SC2012  # a fixed temp path, and `ls -i` is the only
# inode read that works on GNU, BSD and Git Bash alike.
after="$(ls -i "$CLAUDE_TIMESTAMP_FACTS" | awk '{print $1}')"
refutes "facts: replaced by rename, not written in place" test "$before" = "$after"

# ct_write_facts resolves the plugin root via
# `cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd` as a plain command-
# substitution assignment. Under set -e that is NOT a context errexit skips
# (unlike an if, a &&/||, or a negation), so if that cd ever fails the whole
# of session-start.sh used to die right there -- silently swallowing every
# later systemMessage (config-problems banner, tz-unhonoured banner, and the
# first-run banner) along with it, for a script that must always exit 0 and
# never swallow output.
#
# Filesystem permissions cannot force that cd to fail here: its target is
# always an ancestor directory of the very script being executed, so denying
# access to it would also prevent the script from being opened at all (and,
# separately, this sandbox runs as root, which bypasses permission checks
# entirely). Instead, BASH_ENV is used to shadow the `cd` builtin for just
# this one subprocess, failing only the specific "go up two levels" call and
# leaving every other cd (including the one that locates lib/config.sh two
# lines into the script) untouched.
BLOCK_ROOT_CD="$WORK/block-root-cd.sh"
cat > "$BLOCK_ROOT_CD" <<'EOF'
cd() {
  case "$*" in
    *"/../..") return 1 ;;
    *) builtin cd "$@" ;;
  esac
}
EOF

rm -f "$CLAUDE_TIMESTAMP_CONFIG" "$CLAUDE_TIMESTAMP_FACTS"
out="$(printf '{"session_id":"facts"}' | BASH_ENV="$BLOCK_ROOT_CD" bash "$SCRIPTS/session-start.sh")"
status=$?
is "facts: a root-resolution failure still exits 0" "0" "$status"
contains "facts: a root-resolution failure still emits the first-run banner" "/timestamps" "$out"
asserts "facts: a root-resolution failure still writes a valid facts file" jq -e . "$CLAUDE_TIMESTAMP_FACTS"
is "facts: a root-resolution failure falls back to an unknown version" \
   "unknown" "$(jq -r '.clients[].version' "$CLAUDE_TIMESTAMP_FACTS")"

echo
echo "a marker that was actually drawn"

# The facts file proves the hook runner reached this plugin. It cannot prove
# the marker got as far as the screen, and those need opposite fixes: one is an
# install to repair, the other is a client discarding displayContent, which is
# nothing this plugin can do anything about. So record the drawing itself.
fresh
drawn_for() { printf '%s.%s' "$CLAUDE_TIMESTAMP_DRAWN" "${1:-cli}"; }
rm -f "$CLAUDE_TIMESTAMP_DRAWN".*

printf '{"session_id":"d1","index":0,"delta":"hi"}' \
  | CLAUDE_CODE_ENTRYPOINT=claude-desktop bash "$SCRIPTS/message-display.sh" >/dev/null
asserts "drawn: recorded when a marker is emitted" test -r "$(drawn_for claude-desktop)"

# Keyed like the facts file, so a healthy terminal cannot stand in for a
# desktop session that has drawn nothing.
refutes "drawn: not recorded against another client" test -r "$(drawn_for cli)"

age="$(( $(date +%s) - $(cat "$(drawn_for claude-desktop)" 2>/dev/null || echo 0) ))"
asserts "drawn: carries a fresh time" test "$age" -ge 0 -a "$age" -le 5

# Every reason the hook declines to draw must leave no trace, or the record
# claims a marker reached the screen when none did.
rm -f "$CLAUDE_TIMESTAMP_DRAWN".*
printf '{"session_id":"d2","index":0,"delta":"hi"}' \
  | CLAUDE_CODE_ENTRYPOINT=cli bash "$SCRIPTS/message-display.sh" >/dev/null 2>&1
asserts "drawn: recorded for a plain message" test -r "$(drawn_for cli)"

fresh 'ENABLED=off'
rm -f "$CLAUDE_TIMESTAMP_DRAWN".*
printf '{"session_id":"d3","index":0,"delta":"hi"}' \
  | CLAUDE_CODE_ENTRYPOINT=cli bash "$SCRIPTS/message-display.sh" >/dev/null 2>&1
refutes "drawn: nothing recorded when the plugin is off" test -r "$(drawn_for cli)"

fresh 'SUBAGENTS=off'
rm -f "$CLAUDE_TIMESTAMP_DRAWN".*
printf '{"session_id":"d4","agent_id":"sub","index":0,"delta":"hi"}' \
  | CLAUDE_CODE_ENTRYPOINT=cli bash "$SCRIPTS/message-display.sh" >/dev/null 2>&1
refutes "drawn: nothing recorded for a skipped subagent" test -r "$(drawn_for cli)"

# A later flush of the same message draws nothing, so it must record nothing.
fresh
rm -f "$CLAUDE_TIMESTAMP_DRAWN".*
printf '{"session_id":"d5","index":3,"delta":"more"}' \
  | CLAUDE_CODE_ENTRYPOINT=cli bash "$SCRIPTS/message-display.sh" >/dev/null 2>&1
refutes "drawn: nothing recorded for a later batch" test -r "$(drawn_for cli)"

rm -f "$CLAUDE_TIMESTAMP_DRAWN".*

# doctor must not turn "I cannot read the clock" into "a marker was just
# drawn". ct_epoch reports 0 when `date` cannot be reached, which makes every
# age negative, and clamping a negative age to zero would state the most
# reassuring thing possible at the exact moment nothing is known. The clamp is
# still right for a clock that stepped backwards, which is why the two cases
# are told apart rather than merged.
NO_DATE="$WORK/no-date.sh"
cat > "$NO_DATE" <<'EOF'
date() { return 1; }
EOF
printf '%s' 1700000000 > "${CLAUDE_TIMESTAMP_DRAWN}.cli"
out="$(BASH_ENV="$NO_DATE" CLAUDE_CODE_ENTRYPOINT=cli bash "$SCRIPTS/setup.sh" --doctor 2>&1 || true)"
lacks "doctor: an unreadable clock is not reported as a fresh marker" "0s ago" "$out"
contains "doctor: an unreadable clock is reported as unknown" "time unknown" "$out"
rm -f "$CLAUDE_TIMESTAMP_DRAWN".*

echo
echo "enabled switch"

fresh 'ENABLED=off'
is "enabled: parsed from the config" "off" "$CT_ENABLED"

out="$(printf '{"session_id":"off-1","prompt":"hi"}' | bash "$SCRIPTS/user-prompt-submit.sh")"
is "enabled=off: no context is injected" "" "$out"

fresh 'ENABLED=off'
out="$(printf '{"index":0,"session_id":"off-2","delta":"hello"}' | bash "$SCRIPTS/message-display.sh")"
is "enabled=off: no marker is drawn" "" "$out"

# A real turn is recorded with ENABLED=on, then the plugin is switched off
# before session-end.sh runs -- state exists (turns > 0), so the empty output
# proves session-end.sh's own guard fired rather than there being nothing to
# summarise. That is also the realistic "switched off mid-session" path.
fresh 'ENABLED=on'
printf '{"session_id":"off-3","prompt":"hi"}' | bash "$SCRIPTS/user-prompt-submit.sh" >/dev/null
printf 'ENABLED=off\n' > "$CLAUDE_TIMESTAMP_CONFIG"
out="$(printf '{"session_id":"off-3"}' | bash "$SCRIPTS/session-end.sh")"
is "enabled=off: no session summary" "" "$out"

# Switching off mid-session must not strand that session's state files --
# they would otherwise sit until the 7-day sweep instead of being cleared at
# the session's own end.
is "enabled=off: state is still cleared" "" \
   "$(find "$(ct_state_dir)" -name 'off-3*' 2>/dev/null)"

# The facts file must still be written, or /timestamps could never turn the
# plugin back on. COLOR=banana is pinned alongside ENABLED=off so a config
# problem exists that would otherwise produce a systemMessage -- proving
# silence here comes from the ENABLED guard, not from there being nothing to
# report.
fresh 'ENABLED=off' 'COLOR=banana'
rm -f "$CLAUDE_TIMESTAMP_FACTS"
out="$(printf '{"session_id":"off-4"}' | bash "$SCRIPTS/session-start.sh")"
asserts "enabled=off: facts are still published" test -r "$CLAUDE_TIMESTAMP_FACTS"
is "enabled=off: session start stays quiet" "" "$out"

# The tool-timing hook fires per tool call rather than per message, so it
# gets its own ENABLED=off check. TOOL_TIMING=on and a real duration so,
# absent the guard, it would actually write.
#
# Since the glob gate exists, this session's own call would be skipped by the
# gate alone (no session here has a staged sentinel), which would pass this
# assertion for the wrong reason -- the gate, not the ENABLED check the
# comment above claims to exercise. A different session's sentinel is staged
# by hand, the way a concurrent session with timing on would leave one, so
# the gate lets this call through to the per-session flag read, which falls
# back to ct_load_config (this session never staged its own flags) and is
# where ENABLED=off actually has to stop it.
fresh 'ENABLED=off' 'TOOL_TIMING=on'
tool_log="$(ct_tool_log "off-5")"
ct_stage_flag "other" "timing-on" "1"
printf '{"session_id":"off-5","tool_use_id":"t1","tool_name":"Bash","duration_ms":5000,"hook_event_name":"PostToolUse"}' \
  | bash "$SCRIPTS/post-tool-use.sh" >/dev/null
refutes "enabled=off: post-tool-use writes no log" test -s "$tool_log"

# Switching the plugin off mid-session must actually stop it. The tool hook
# reads a cached decision, so the prompt hook has to be able to write "off" --
# and it could not, when the staging sat behind the master switch.
fresh 'ENABLED=on' 'TOOL_TIMING=on'
sid="offmid"; base="$(ct_state_file "$sid")"
printf '{"session_id":"%s","cwd":"%s"}' "$sid" "$WORK" | bash "$SCRIPTS/user-prompt-submit.sh" >/dev/null
printf 'ENABLED=off\nTOOL_TIMING=on\n' > "$CLAUDE_TIMESTAMP_CONFIG"
printf '{"session_id":"%s","cwd":"%s"}' "$sid" "$WORK" | bash "$SCRIPTS/user-prompt-submit.sh" >/dev/null
is "tool timing: the master switch reaches the staged flag" "off" \
   "$(ct_read_flag "$sid" "enabled")"
printf '{"session_id":"%s","tool_name":"Bash","hook_event_name":"PostToolUse","duration_ms":3000}' "$sid" \
  | bash "$SCRIPTS/post-tool-use.sh" >/dev/null
is "tool timing: nothing is recorded once switched off" "" \
   "$(cat "$base.tools" 2>/dev/null)"

# And the sentinel must be cleared, or one switched-off session keeps every
# other session on the machine paying the parse it exists to avoid.
refutes "tool timing: the sentinel is cleared when it is switched off" \
        test -e "$base.timing-on"

# The opposite transition: the sentinel appears when a session wants timing.
fresh 'ENABLED=on' 'TOOL_TIMING=on'
printf '{"session_id":"onmid","cwd":"%s"}' "$WORK" | bash "$SCRIPTS/user-prompt-submit.sh" >/dev/null
asserts "tool timing: the sentinel appears when a session wants it" \
        test -e "$(ct_state_file onmid).timing-on"

fresh 'ENABLED=on'
out="$(printf '{"index":0,"session_id":"on-1","delta":"hello"}' | bash "$SCRIPTS/message-display.sh")"
contains "enabled=on: the marker comes back" "hello" "$out"

fresh 'ENABLED=banana'
is "enabled: an unusable value falls back to on" "on" "$CT_ENABLED"
contains "enabled: and says so" "ENABLED=banana is not valid" "$CT_CONFIG_PROBLEMS"

fresh
bash "$SCRIPTS/setup.sh" --enabled=off >/dev/null
ct_load_config
is "enabled: setup.sh writes it" "off" "$CT_ENABLED"
bash "$SCRIPTS/setup.sh" --enabled=on >/dev/null
ct_load_config
is "enabled: and writes it back" "on" "$CT_ENABLED"
refutes "enabled: setup.sh refuses a bad value" \
  bash "$SCRIPTS/setup.sh" --enabled=banana

# A project may switch the plugin off for one repository without touching the
# user's own configuration.
project="$WORK/proj-enabled"
mkdir -p "$project"
( cd "$project" && CLAUDE_TIMESTAMP_CONFIG="" HOME="$WORK" \
    bash "$SCRIPTS/setup.sh" --project --enabled=off >/dev/null )
contains "enabled: a project can pin it" "ENABLED=off" \
  "$(cat "$project/.claude/claude-timestamp.conf" 2>/dev/null)"

echo
echo "slow turn attribution"

fresh
mkdir -p "$(ct_state_dir)"
log="$(ct_state_dir)/attr.turntools"

printf 'Bash 118.000 ok\nRead 2.000 ok\n' > "$log"
is "attribution: names the dominant tool" "Bash 1m58s" "$(ct_dominant_tool "$log" 134)"

printf 'Bash 40.000 ok\nRead 2.000 ok\n' > "$log"
refutes "attribution: silent when no tool dominates" ct_dominant_tool "$log" 134

printf 'Bash 45.000 ok\n' > "$log"
is "attribution: sub-minute reads in seconds" "Bash 45s" "$(ct_dominant_tool "$log" 60)"

printf 'Bash 30.000 ok\nRead 32.000 ok\n' > "$log"
is "attribution: sums per tool, not per call" "Read 32s" "$(ct_dominant_tool "$log" 62)"

# Tool calls run concurrently, so four 30s Bash calls can finish inside a 32s
# turn. The per-tool sum (120s) must never be rendered larger than the turn
# actually took.
printf 'Bash 30.000 ok\nBash 30.000 ok\nBash 30.000 ok\nBash 30.000 ok\n' > "$log"
is "attribution: clamps a duration sum larger than the turn" "Bash 32s" "$(ct_dominant_tool "$log" 32)"

: > "$log"
refutes "attribution: silent on an empty log" ct_dominant_tool "$log" 134
refutes "attribution: silent on a missing log" ct_dominant_tool "$(ct_state_dir)/nope" 134
refutes "attribution: silent when the turn was instant" ct_dominant_tool "$log" 0

# The per-turn log is appended by one hook while another reads it, so a torn
# final line is possible. A partial line must be skipped, not summed as a tool
# named by whatever prefix landed.
# The fragment must be able to WIN, or the assertion proves nothing. A line torn
# before its duration (`WebFe`) has an empty second field, which awk coerces to
# 0 -- that never beats a real entry, so the guard is never consulted and the
# test passes with or without it. Tear it MID-DURATION instead: `55.5` is
# numeric, beats the 20 above it, and sits on a two-field line, so without the
# guard it wins (clamped to the 32s turn) and with the guard it is rejected,
# leaving Bash's 20s -- which is why the turn total here is 32, not 60: at 60,
# Bash's own 20s would not clear the "at least half the turn" bar below and
# the fixture would prove nothing either way.
fresh
log="$WORK/torn.tools"
printf 'Bash 20.000 ok\nWebFetch 55.5' > "$log"
is "attribution: a torn line is skipped" "Bash 20s" "$(ct_dominant_tool "$log" 32)"

printf 'Bash 20.000 ok\nRead 55.5 ok\n' > "$log"
is "attribution: a malformed duration is skipped" "Bash 20s" "$(ct_dominant_tool "$log" 32)"

# The per-turn log must be cleared at each prompt, or the second turn inherits
# the first turn's tools and blames the wrong one.
fresh 'TOOL_TIMING=on'
printf '{"session_id":"turnlog","prompt":"hi"}' | bash "$SCRIPTS/user-prompt-submit.sh" >/dev/null
printf 'Bash 99\n' > "$(ct_turn_tool_log turnlog)"
printf '{"session_id":"turnlog","prompt":"hi"}' | bash "$SCRIPTS/user-prompt-submit.sh" >/dev/null
is "attribution: the per-turn log is cleared each prompt" "" "$(cat "$(ct_turn_tool_log turnlog)")"

# End to end through the marker.
fresh 'TOOL_TIMING=on' 'SLOW_AFTER=1'
printf '{"session_id":"marker","prompt":"hi"}' | bash "$SCRIPTS/user-prompt-submit.sh" >/dev/null
printf '%s' "$(( $(date +%s) - 200 ))" > "$(ct_state_file marker)"
printf 'Bash 190.000 ok\n' > "$(ct_turn_tool_log marker)"
out="$(strip_ansi "$(printf '{"index":0,"session_id":"marker","delta":"x"}' \
  | bash "$SCRIPTS/message-display.sh" | jq -r '.hookSpecificOutput.displayContent')")"
contains "attribution: appears in the marker" "Bash 3m10s" "$out"
contains "attribution: the separator is a middle dot" "· Bash" "$out"

# Off by default, because it rides on TOOL_TIMING.
fresh 'SLOW_AFTER=1'
printf '{"session_id":"noattr","prompt":"hi"}' | bash "$SCRIPTS/user-prompt-submit.sh" >/dev/null
printf '%s' "$(( $(date +%s) - 200 ))" > "$(ct_state_file noattr)"
printf 'Bash 190.000 ok\n' > "$(ct_turn_tool_log noattr)"
out="$(strip_ansi "$(printf '{"index":0,"session_id":"noattr","delta":"x"}' \
  | bash "$SCRIPTS/message-display.sh" | jq -r '.hookSpecificOutput.displayContent')")"
lacks "attribution: absent when tool timing is off" "Bash" "$out"

# A fast turn is not annotated even when a tool dominated it.
fresh 'TOOL_TIMING=on' 'SLOW_AFTER=600'
printf '{"session_id":"fast","prompt":"hi"}' | bash "$SCRIPTS/user-prompt-submit.sh" >/dev/null
printf '%s' "$(( $(date +%s) - 200 ))" > "$(ct_state_file fast)"
printf 'Bash 190.000 ok\n' > "$(ct_turn_tool_log fast)"
out="$(strip_ansi "$(printf '{"index":0,"session_id":"fast","delta":"x"}' \
  | bash "$SCRIPTS/message-display.sh" | jq -r '.hookSpecificOutput.displayContent')")"
lacks "attribution: absent on a fast turn" "Bash" "$out"

echo
echo "away context"

# The gap is measured from the previous turn's close, not the previous
# message, so the fixture stages a .closed rather than a .last.
fresh 'IDLE_AFTER=1800'
mkdir -p "$(ct_state_dir)"
printf '%s' "$(( $(date +%s) - 10800 ))" > "$(ct_state_file away).closed"
out="$(printf '{"session_id":"away","prompt":"hi"}' | bash "$SCRIPTS/user-prompt-submit.sh" \
  | jq -r '.hookSpecificOutput.additionalContext')"
contains "away: a long gap is reported" "after a 3h break" "$out"
contains "away: the time is still there" "Message sent at local time" "$out"

fresh 'IDLE_AFTER=1800'
printf '%s' "$(( $(date +%s) - 60 ))" > "$(ct_state_file near).closed"
out="$(printf '{"session_id":"near","prompt":"hi"}' | bash "$SCRIPTS/user-prompt-submit.sh" \
  | jq -r '.hookSpecificOutput.additionalContext')"
lacks "away: a short gap is not reported" "break" "$out"

fresh 'IDLE_AFTER=0'
printf '%s' "$(( $(date +%s) - 10800 ))" > "$(ct_state_file disabled).closed"
out="$(printf '{"session_id":"disabled","prompt":"hi"}' | bash "$SCRIPTS/user-prompt-submit.sh" \
  | jq -r '.hookSpecificOutput.additionalContext')"
lacks "away: silent when idle marking is off" "break" "$out"

fresh 'IDLE_AFTER=1800' 'INJECT_CONTEXT=false'
printf '%s' "$(( $(date +%s) - 10800 ))" > "$(ct_state_file noinject).closed"
out="$(printf '{"session_id":"noinject","prompt":"hi"}' | bash "$SCRIPTS/user-prompt-submit.sh")"
is "away: nothing is injected when context injection is off" "" "$out"

fresh 'IDLE_AFTER=1800'
out="$(printf '{"session_id":"firstprompt","prompt":"hi"}' | bash "$SCRIPTS/user-prompt-submit.sh" \
  | jq -r '.hookSpecificOutput.additionalContext')"
lacks "away: the first prompt of a session has no gap" "break" "$out"

echo
echo "context zone"

# The zone appended to the model-facing string is not decoration on the
# default format: the hook appends it whatever CONTEXT_FORMAT renders,
# precisely so the model can resolve the offset when the format itself omits
# one. Every preset is asserted separately, because "it still works on 24h"
# is exactly what this regression looks like from the outside.
#
# The clock is never recomputed into an expected string. The shape is matched
# instead -- digits, one space, the zone -- so a second ticking over between
# the hook and the assertion cannot fail a test about where the zone goes.

# What the platform calls TZ=UTC, asked of it rather than assumed: Git Bash on
# Windows answers GMT where Linux and macOS answer UTC, and both are correct
# names for the same zone. These cases are about where the zone lands in the
# rendered string, so the name itself is a detail they should not be pinning.
zone_utc="$(TZ=UTC date '+%Z')"

fresh 'TZ=UTC'
out="$(printf '{"session_id":"zone24","prompt":"hi"}' | bash "$SCRIPTS/user-prompt-submit.sh")"
is "zone: the injection is a UserPromptSubmit result" "UserPromptSubmit" \
   "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.hookEventName')"

# Proof this run reached the injection path rather than leaving early: the
# turn-start stamp is written on the way there. Without it every assertion
# below would be about a string the hook never produced.
asserts "zone: the injecting run also stamped the turn start" test -r "$(ct_state_file zone24)"

ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')"
rest="${ctx#Message sent at local time }"
case "$rest" in
  [0-9][0-9]:[0-9][0-9]:[0-9][0-9]" $zone_utc")
    pass "zone: 24h puts the zone one space after the time" ;;
  *) fail "zone: 24h puts the zone one space after the time" "HH:MM:SS $zone_utc" "$rest" ;;
esac

# The ISO rendering ends at the seconds and carries no offset of its own, so
# the trailing zone is the only thing that resolves it. This is the preset the
# omission would have hurt most.
fresh 'TZ=UTC' 'CONTEXT_FORMAT=iso'
ctx="$(printf '{"session_id":"zoneiso","prompt":"hi"}' | bash "$SCRIPTS/user-prompt-submit.sh" \
  | jq -r '.hookSpecificOutput.additionalContext')"
rest="${ctx#Message sent at local time }"
case "$rest" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]" $zone_utc")
    pass "zone: iso carries no offset, so the zone resolves it" ;;
  *) fail "zone: iso carries no offset, so the zone resolves it" "YYYY-MM-DDTHH:MM:SS $zone_utc" "$rest" ;;
esac

fresh 'TZ=UTC' 'CONTEXT_FORMAT=short'
ctx="$(printf '{"session_id":"zoneshort","prompt":"hi"}' | bash "$SCRIPTS/user-prompt-submit.sh" \
  | jq -r '.hookSpecificOutput.additionalContext')"
rest="${ctx#Message sent at local time }"
case "$rest" in
  [0-9][0-9]:[0-9][0-9]" $zone_utc")
    pass "zone: short keeps the zone after a format that drops the seconds" ;;
  *) fail "zone: short keeps the zone after a format that drops the seconds" "HH:MM $zone_utc" "$rest" ;;
esac

# The zone goes after the AM/PM marker, not between the time and it.
fresh 'TZ=UTC' 'CONTEXT_FORMAT=12h'
ctx="$(printf '{"session_id":"zone12h","prompt":"hi"}' | bash "$SCRIPTS/user-prompt-submit.sh" \
  | jq -r '.hookSpecificOutput.additionalContext')"
rest="${ctx#Message sent at local time }"
case "$rest" in
  [0-9]:[0-9][0-9]" "[AP]M" $zone_utc"|[0-9][0-9]:[0-9][0-9]" "[AP]M" $zone_utc")
    pass "zone: 12h puts the zone after the AM/PM marker" ;;
  *) fail "zone: 12h puts the zone after the AM/PM marker" "H:MM AM $zone_utc" "$rest" ;;
esac

# %I is zero-padded and the trim happens before the zone is appended, so
# appending must not resurrect the pad.
case "$rest" in
  0*) fail "zone: 12h still trims the leading zero with the zone appended" "no leading zero" "$rest" ;;
  *)  pass "zone: 12h still trims the leading zero with the zone appended" ;;
esac

# Anything containing a % is a raw strftime string rather than a preset, and
# gets the same treatment.
fresh 'TZ=UTC' 'CONTEXT_FORMAT=%H'
ctx="$(printf '{"session_id":"zoneraw","prompt":"hi"}' | bash "$SCRIPTS/user-prompt-submit.sh" \
  | jq -r '.hookSpecificOutput.additionalContext')"
rest="${ctx#Message sent at local time }"
case "$rest" in
  [0-9][0-9]" $zone_utc") pass "zone: a raw strftime format still gets the zone" ;;
  *) fail "zone: a raw strftime format still gets the zone" "HH $zone_utc" "$rest" ;;
esac

# A pinned zone that this platform can honour is the one the string is
# labelled with -- never the machine's own. Needs a timezone database, and
# needs the machine not to already be in the probe zone, or the negative
# assertion would be asserting nothing.
zone_local="$(date '+%Z')"
if ct_tz_supported && [ "$zone_local" != "JST" ]; then
  fresh 'TZ=Asia/Tokyo'
  ctx="$(printf '{"session_id":"zonetokyo","prompt":"hi"}' | bash "$SCRIPTS/user-prompt-submit.sh" \
    | jq -r '.hookSpecificOutput.additionalContext')"
  is "zone: a honoured pinned zone supplies the abbreviation" "JST" "${ctx##* }"
  lacks "zone: a honoured pinned zone never shows the machine's abbreviation" "$zone_local" "$ctx"
else
  skip "zone: a honoured pinned zone supplies the abbreviation" "no timezone database, or this machine is already JST"
  skip "zone: a honoured pinned zone never shows the machine's abbreviation" "no timezone database, or this machine is already JST"
fi

# Nothing pinned: the label is whatever the machine says it is. %Z does not
# change across a minute boundary, so this one can be compared directly.
fresh
ctx="$(printf '{"session_id":"zonenone","prompt":"hi"}' | bash "$SCRIPTS/user-prompt-submit.sh" \
  | jq -r '.hookSpecificOutput.additionalContext')"
is "zone: with nothing pinned the label is the machine's own" "$zone_local" "${ctx##* }"

# A pinned IANA name on a platform with no timezone database, simulated by
# priming the memoised probe in the hook's own environment. ct_now ignores the
# zone it cannot honour and renders local time; the abbreviation has to follow
# it down, because local time wearing a foreign label is the one output that
# is actually wrong rather than merely not what was asked for.
fresh 'TZ=Asia/Tokyo' 'CONTEXT_FORMAT=short'
cl_ref1="$(date '+%H:%M') $zone_local"
ctx="$(printf '{"session_id":"zonenotz","prompt":"hi"}' \
  | CT_TZ_SUPPORTED=no bash "$SCRIPTS/user-prompt-submit.sh" \
  | jq -r '.hookSpecificOutput.additionalContext')"
cl_ref2="$(date '+%H:%M') $zone_local"
rest="${ctx#Message sent at local time }"
is_clock "zone: an unhonourable zone drags the time and the label down together" \
  "$cl_ref1" "$rest" "$cl_ref2"
if [ "$zone_local" != "JST" ]; then
  lacks "zone: local time is never labelled with a zone that was not honoured" "JST" "$ctx"
else
  skip "zone: local time is never labelled with a zone that was not honoured" "this machine is already JST"
fi

# The away clause is appended after the zone, so a long break can never
# swallow it. The gap is measured from the previous turn's close, so the
# fixture stages a .closed.
fresh 'TZ=UTC' 'IDLE_AFTER=1800'
printf '%s' "$(( $(date +%s) - 10800 ))" > "$(ct_state_file zoneaway).closed"
ctx="$(printf '{"session_id":"zoneaway","prompt":"hi"}' | bash "$SCRIPTS/user-prompt-submit.sh" \
  | jq -r '.hookSpecificOutput.additionalContext')"
rest="${ctx#Message sent at local time }"
case "$rest" in
  [0-9][0-9]:[0-9][0-9]:[0-9][0-9]" $zone_utc, after a 3h break")
    pass "zone: the away clause follows the zone, comma and all" ;;
  *) fail "zone: the away clause follows the zone, comma and all" "HH:MM:SS UTC, after a 3h break" "$rest" ;;
esac

echo
echo "asset format"

# Every README screenshot is a lossless WebP (see tools/screenshots/screenshots.py's
# save_image / save_animation), never a PNG or a GIF -- checked by magic bytes,
# not by extension, so a file merely renamed to .webp cannot pass. This is what
# stops a future shot silently reverting to PNG.
bad_assets="$(for f in "$ROOT"/assets/*; do
  [ -f "$f" ] || continue
  sig="$(head -c 12 "$f" | tail -c 4)"
  [ "$sig" = "WEBP" ] || basename "$f"
done)"
is "every file in assets/ is a WebP" "" "$bad_assets"

echo
echo "display width"

# The wizard's own column counter. setup.sh ends in `main "$@"`, so sourcing it
# would run the whole thing; lift just this function out of the file instead,
# the same way the flag-table case above reads CT_FLAG_TABLE.
eval "$(sed -n '/^_ct_display_width() {$/,/^}$/p' "$SCRIPTS/setup.sh")"

is "width: plain ASCII counts its characters"  "3" "$(_ct_display_width 'abc')"
is "width: a template made only of ASCII"      "5" "$(_ct_display_width '%time')"
is "width: an empty string is zero columns"    "0" "$(_ct_display_width '')"

# A UTF-8 sequence draws one column, not one per byte. Both of these characters
# appear in templates the wizard previews.
is "width: a two-byte character is one column"   "1" "$(_ct_display_width '·')"
is "width: a three-byte character is one column" "1" "$(_ct_display_width '→')"

# The bug this function exists to fix. printf's %-38s pads by bytes, so the
# default template's preview used to land a column early. The byte length is
# asserted next to the display width, because the claim is that the two differ:
# a regression that made them agree again would otherwise pass silently.
dw_tpl='[{%date }%time{ %elapsed}{ · %tool}]'
is "width: the default template is 37 bytes" "37" \
  "$(printf '%s' "$dw_tpl" | LC_ALL=C wc -c | tr -d ' ')"
is "width: but draws only 36 columns"        "36" "$(_ct_display_width "$dw_tpl")"

# The argument is data. It reaches printf only as the value behind a '%s', so a
# marker template carrying a conversion specifier is counted, never applied --
# a template is free-text a user types, and '%s%s' would eat the pad width.
is "width: a percent conversion is counted, not interpreted" "2" "$(_ct_display_width '%d')"
is "width: and so is a pair of them"                         "4" "$(_ct_display_width '%s%s')"

# printf '%s' does not expand escapes in its argument either, so a literal
# backslash followed by t is the two characters it looks like.
is "width: a literal backslash escape is two columns" "2" "$(_ct_display_width '\t')"

# Padding is the whole point, so the spaces the preview has to account for are
# counted rather than trimmed.
is "width: surrounding whitespace is counted, not trimmed" "5" "$(_ct_display_width '  a  ')"

# LC_ALL=C inside the function puts tr on raw bytes, so the answer cannot depend
# on the locale the wizard happens to be run under.
is "width: locale-independent under LC_ALL=C" "1" \
  "$(export LC_ALL=C; _ct_display_width '→')"
dw_utf8_locale=""
for dw_cand in C.UTF-8 C.utf8 en_US.UTF-8; do
  if [ "$(LC_ALL="$dw_cand" locale charmap 2>/dev/null)" = "UTF-8" ]; then
    dw_utf8_locale="$dw_cand"; break
  fi
done
if [ -n "$dw_utf8_locale" ]; then
  is "width: and the same under a UTF-8 locale" "1" \
    "$(export LC_ALL="$dw_utf8_locale"; _ct_display_width '→')"
else
  skip "width: and the same under a UTF-8 locale" "no UTF-8 locale on this machine"
fi

# Two inputs where what this function counts and what a terminal draws come
# apart. The contract's first sentence is that it returns the columns a string
# occupies; what it actually counts is characters, bytes minus continuation
# bytes, and characters are not columns. Quarantined rather than pinned: the
# numbers returned today are the gap itself, so writing them down as the
# expectation would freeze a wcwidth bug into the suite as if it were the
# specification. The columns each string really draws are recorded instead.
# Neither input is reachable from a shipped template, which is why this is
# latent rather than something anyone has seen misalign.
#
# SUSPECTED BUG: a four-byte emoji occupies two columns and counts one, so a
# template carrying one would be padded a column too wide.
skip "width: an emoji counts the two columns it draws" \
  "SUSPECTED BUG: input the grinning-face emoji draws 2 columns, _ct_display_width returns 1"
# SUSPECTED BUG: a combining accent draws no column of its own, so "e" followed
# by U+0301 occupies one column and counts two -- a column too narrow, the
# opposite error. The contract predicts a third answer again ("a combining mark
# counts only its base"), so the intended value is unclear as well as unmet;
# flagged rather than guessed at.
skip "width: a combining accent draws no column of its own" \
  "SUSPECTED BUG: input e followed by U+0301 draws 1 column, _ct_display_width returns 2"

# The alignment this function is the only reason for. The wizard prints three
# template previews padded to a common width, two of the templates containing a
# multi-byte character, and the rendered markers must all start in the same
# column. Measured through the wizard rather than asserted against fixed text,
# because the markers contain the current clock.
fresh
dw_out="$(printf 'off\nlocal\nshort\non\n30\n0\noff\noff\ncyan\n\nfalse\nn\n' \
  | bash "$SCRIPTS/setup.sh" 2>/dev/null)"
dw_cols=""
# The expected column is derived from constants, not from _ct_display_width, so
# the measurement cannot cancel out a regression in the thing it is measuring:
# the leading number is each template's character count, counted by hand.
for dw_pair in "36:[{%date }%time{ %elapsed}{ · %tool}]" "5:%time" "18:%time{ → %elapsed}"; do
  dw_n="${dw_pair%%:*}"; dw_t="${dw_pair#*:}"
  dw_lead=""
  while IFS= read -r dw_line; do
    dw_line="$(strip_ansi "$dw_line")"
    # The template is quoted so its braces and brackets match literally, and the
    # trailing space keeps '%time' off the '%time{ ... }' line.
    case "$dw_line" in
      "  $dw_t "*)
        dw_rest="${dw_line#"  $dw_t"}"
        dw_lead="${dw_rest%%[! ]*}"
        ;;
    esac
  done <<DWOUT
$dw_out
DWOUT
  dw_cols="$dw_cols$(( 2 + dw_n + ${#dw_lead} )) "
done
# Two leading spaces, a field padded to 38 columns, one separator space.
is "wizard: all three template previews start the marker in one column" \
  "41 41 41 " "$dw_cols"


if command -v jq >/dev/null 2>&1; then
  echo
  echo "session end reconciles an open turn"

  # A session can end with no Stop behind it, which leaves the last turn open:
  # a start file with no .closed sibling. session-end.sh closes that turn
  # itself, at the time the last message was drawn, BEFORE it reads any
  # totals -- so the final turn's waiting time reaches the summary and the
  # history row instead of being dropped.
  #
  # Every fixture below plants exactly that state directly under the session's
  # state path, and the only thing that varies between cases is what .last
  # says, which is the one input the reconciliation reads. The session is an
  # hour old, the open turn 90s old, and 100s of waiting is already banked
  # from the turns that closed normally -- so an unreconciled run reports
  # 1m40s and a reconciled one 2m40s, and no case can be satisfied by both.
  #
  # One reading of the clock per fixture, shared by every offset, so a case
  # cannot straddle a second boundary between two `date` calls.
  seed_open_turn() {
    # $1 session id; $2, when given, how many seconds ago the last message was
    # drawn (negative puts it in the future). Omitting $2 plants no .last.
    local b now
    b="$(ct_state_file "$1")"
    mkdir -p "$(ct_state_dir)"
    now="$(date +%s)"
    printf '%s' "$(( now - 3600 ))" > "$b.start"
    printf '2'   > "$b.turns"
    printf '100' > "$b.wait"
    printf '%s' "$(( now - 90 ))" > "$b"
    if [ "$#" -gt 1 ]; then
      printf '%s' "$(( now - $2 ))" > "$b.last"
    fi
    return 0
  }

  end_open_session() {
    printf '{"session_id":"%s"}' "$1" \
      | bash "$SCRIPTS/session-end.sh" | jq -r '.systemMessage // ""'
  }

  fresh
  seed_open_turn "reopen" 30
  out="$(end_open_session reopen)"
  contains "session end counts the turn no Stop ever closed" "2m40s of it waiting" "$out"
  # Closing a turn must not open one: the count is whatever the prompt hook
  # recorded, untouched by the reconciliation that runs beside it.
  contains "reconciling the last turn does not invent one" "over 2 turns," "$out"

  # The control that makes the case above a statement about the code rather
  # than about the clock. Identical state, no .last, so the reconciliation has
  # no end time to close at and contributes nothing: the 60s above came from
  # .last, not from `date`.
  fresh
  seed_open_turn "reopen-none"
  contains "with no .last the same fixture reports only the banked wait" \
    "1m40s of it waiting" "$(end_open_session reopen-none)"

  # Stop already closed this turn and already banked what it cost. The .closed
  # sibling is the record of that, and finding one makes the close a no-op --
  # otherwise every session that ended tidily would count its last turn twice.
  fresh
  seed_open_turn "reopen-closed" 30
  printf '%s' "$(( $(date +%s) - 30 ))" > "$(ct_state_file reopen-closed).closed"
  contains "a turn Stop already closed is not counted a second time" \
    "1m40s of it waiting" "$(end_open_session reopen-closed)"

  # The reconciliation happens before the totals are read, so it reaches the
  # history row too -- field 4 is the waiting figure ct_history_append is
  # handed. Without it the row would say 100.
  fresh 'HISTORY=on'
  seed_open_turn "reopen-hist" 30
  end_open_session reopen-hist >/dev/null
  is "the reconciled total is what the history row records" "160" \
     "$(awk -F'\t' 'END{print $4}' "$CLAUDE_TIMESTAMP_HISTORY")"

  # SUMMARY and HISTORY are independent, and the reconciliation sits upstream
  # of both: switching the printed summary off must not switch off the figure
  # the row is built from.
  fresh 'SUMMARY=off' 'HISTORY=on'
  seed_open_turn "reopen-quiet" 30
  is "SUMMARY=off prints nothing even with a turn to reconcile" "" \
     "$(end_open_session reopen-quiet)"
  is "the row still carries the reconciled total with the summary off" "160" \
     "$(awk -F'\t' 'END{print $4}' "$CLAUDE_TIMESTAMP_HISTORY")"

  # A turn that drew nothing at all -- straight into a long tool call, then an
  # interrupt -- leaves .last pointing at the PREVIOUS turn. It contributes
  # nothing; what it must never do is subtract.
  fresh
  seed_open_turn "reopen-before" 200
  contains "a .last older than the open turn never decrements the total" \
    "1m40s of it waiting" "$(end_open_session reopen-before)"

  fresh
  seed_open_turn "reopen-equal" 90
  contains "a .last exactly at the turn's start contributes nothing" \
    "1m40s of it waiting" "$(end_open_session reopen-equal)"

  # A clock that jumped forward can put .last past now, which would otherwise
  # hand the summary more waiting than the session lasted. The clamp in
  # ct_session_totals runs after the reconciliation, so it still applies.
  fresh 'HISTORY=on'
  seed_open_turn "reopen-skew" -100000
  contains "waiting from a future .last is clamped to the elapsed total" \
    "1h00m of it waiting" "$(end_open_session reopen-skew)"
  is "the row never claims more waiting than the session lasted" "clamped" \
     "$(awk -F'\t' 'END{print ($4 <= $2) ? "clamped" : $4 " > " $2}' "$CLAUDE_TIMESTAMP_HISTORY")"

  # .last is a file on disk, so it can be truncated or half-written. Both read
  # as 0, which is the no-end-time case above, and neither takes the hook down
  # under its `set -e`.
  fresh
  seed_open_turn "reopen-junk"
  printf 'abc' > "$(ct_state_file reopen-junk).last"
  status=0
  out="$(printf '{"session_id":"reopen-junk"}' | bash "$SCRIPTS/session-end.sh")" || status=$?
  is "a corrupt .last does not fail the hook" "0" "$status"
  contains "a corrupt .last leaves the banked wait alone" "1m40s of it waiting" \
    "$(printf '%s' "$out" | jq -r '.systemMessage')"

  fresh
  seed_open_turn "reopen-empty"
  : > "$(ct_state_file reopen-empty).last"
  status=0
  out="$(printf '{"session_id":"reopen-empty"}' | bash "$SCRIPTS/session-end.sh")" || status=$?
  is "an empty .last does not fail the hook" "0" "$status"
  contains "an empty .last leaves the banked wait alone" "1m40s of it waiting" \
    "$(printf '%s' "$out" | jq -r '.systemMessage')"

  # The close writes a .closed sibling of its own, and ct_clear_state runs
  # after it. Nothing the reconciliation writes may outlive the session.
  fresh
  seed_open_turn "reopen-clear" 30
  end_open_session reopen-clear >/dev/null
  is "reconciliation leaves nothing behind for the clear to miss" "0" \
     "$(ls -1 "$(ct_state_file reopen-clear)"* 2>/dev/null | wc -l | tr -d ' ')"

  fresh
fi

echo
echo "closing a turn by session id"

# ct_turn_close is the only close the hooks ever call: stop.sh, session-end.sh
# and user-prompt-submit.sh each name the session by id and none of them knows
# the state layout. ct_close_turn itself has cover under "turn accounting", so
# what is asserted here is the seam between the two -- the id reduction, and
# the promise that every path returns 0, which is the only thing keeping three
# `set -euo pipefail` hooks alive when a payload carries something odd.

fresh
tc_now="$(date +%s)"
tc_base="$(ct_state_file "tc")"
printf '%s' "$(( tc_now - 40 ))" > "$tc_base"
tc_end="$(date +%s)"
ct_turn_close "tc" "$tc_end"
is_near "turn close: banks the turn against the id's own state file" 40 \
  "$(ct_read_counter "$tc_base.wait")" 2
# The end time is captured rather than computed inline so the stamp can be
# pinned to it, not merely shown to exist. A close that always stamped the
# turn's own start -- the value the clamped branch below writes -- would
# satisfy an existence check while getting every ordinary turn wrong, and
# ct_record_away measures the next break from exactly this number.
is "turn close: and marks the turn closed at the end it was handed" "$tc_end" \
  "$(ct_read_counter "$tc_base.closed")"
tc_closed="$(ct_read_counter "$tc_base.closed")"

# A hook can cause the model to run again, so a turn seeing two closes is a
# case to survive. The second one carries a later end time and must still move
# neither the total nor the close time.
ct_turn_close "tc" "$(( tc_now + 300 ))"
is_near "turn close: a second close adds nothing to the total" 40 \
  "$(ct_read_counter "$tc_base.wait")" 2
is "turn close: and does not move the close time" "$tc_closed" \
  "$(ct_read_counter "$tc_base.closed")"

# An end before the turn's own start means the turn drew no message of its own,
# so it contributes nothing -- but it is still closed, and closed at its start
# rather than at that earlier time. ct_record_away measures the user's break
# from .closed, so a stamp from before this turn opened would hand the next gap
# this turn's whole duration on top of the real break.
fresh
tc_now="$(date +%s)"
tc_base="$(ct_state_file "tc2")"
printf '%s' "$tc_now" > "$tc_base"
# The running total is seeded rather than left absent, because an absent .wait
# and a .wait holding a negative number both read back as 0: a close that
# skipped the clamp and banked `ended - started` would write -500 here and pass
# an assertion that expected 0. Against a real total the wrong write is visible.
printf '88' > "$tc_base.wait"
ct_turn_close "tc2" "$(( tc_now - 500 ))"
is "turn close: an end before the start contributes nothing" "88" \
  "$(ct_read_counter "$tc_base.wait")"
asserts "turn close: but the turn is closed anyway" test -r "$tc_base.closed"
is "turn close: at its own start, never at the earlier end" "$tc_now" \
  "$(ct_read_counter "$tc_base.closed")"

# No end time at all. `${2:-0}` collapses it to 0, which is the same value
# session-end.sh arrives with when .last was never written -- a session that
# ended mid-turn having drawn nothing. The turn is closed at its start, and the
# running total is left exactly as it was.
#
# The start is put 50 seconds in the past on purpose. With it stamped at "now",
# a close that quietly substituted the current time for the missing argument
# would land on the same .closed and the same total within the same second, and
# this case would pass against exactly the behaviour it exists to rule out.
fresh
tc_now="$(date +%s)"
tc_start="$(( tc_now - 50 ))"
tc_base="$(ct_state_file "tc3")"
printf '%s' "$tc_start" > "$tc_base"
printf '77' > "$tc_base.wait"
ct_turn_close "tc3" ""
is "turn close: an empty end time still closes the turn" "$tc_start" \
  "$(ct_read_counter "$tc_base.closed")"
is "turn close: and leaves the banked wait untouched" "77" \
  "$(ct_read_counter "$tc_base.wait")"

# A non-numeric or negative end is not a time. Nothing is written, so the turn
# stays open for whoever can close it properly.
fresh
tc_base="$(ct_state_file "tc4")"
printf '%s' "$(date +%s)" > "$tc_base"
# Seeded, for the reason the clamped case above gives: a total that already
# holds a number distinguishes "left alone" from "written with something that
# reads back as zero", which an absent file cannot.
printf '13' > "$tc_base.wait"
ct_turn_close "tc4" "abc"
refutes "turn close: a non-numeric end writes no .closed" test -e "$tc_base.closed"
ct_turn_close "tc4" "-5"
refutes "turn close: a negative end writes no .closed" test -e "$tc_base.closed"
is "turn close: and neither banks any waiting" "13" "$(ct_read_counter "$tc_base.wait")"

# The id arrives in a hook payload, so it is reduced to a filename before it
# can steer a write anywhere. An id that reduces to nothing is a silent no-op:
# the hooks call this as a bare statement, so refusing loudly would be worse
# than doing nothing.
fresh
tc_before="$(ls -1A "$TMPDIR")"
asserts "turn close: an empty id returns 0"              ct_turn_close "" 12345
asserts "turn close: an id of only separators returns 0" ct_turn_close "///" 12345
asserts "turn close: an id of only dots returns 0"       ct_turn_close ".." 12345
is "turn close: and none of them writes inside the state directory" "0" \
  "$(ls -1A "$(ct_state_dir)" | wc -l | tr -d ' ')"
is "turn close: nor beside it, under the state dir's own name or its parent's" \
  "$tc_before" "$(ls -1A "$TMPDIR")"

# A traversal id flattens to one name inside the state directory, and that
# file -- not the path it spells -- is the turn that gets closed.
fresh
tc_now="$(date +%s)"
tc_base="$(ct_state_dir)/etcpasswd"
printf '%s' "$(( tc_now - 30 ))" > "$tc_base"
tc_before="$(ls -1A "$TMPDIR")"
ct_turn_close "../../etc/passwd" "$tc_now"
is "turn close: a traversal id closes the flattened file" "30" \
  "$(ct_read_counter "$tc_base.wait")"
is "turn close: and writes only siblings of that name" \
  "etcpasswd etcpasswd.closed etcpasswd.wait" \
  "$(ls -1A "$(ct_state_dir)" | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
is "turn close: and nothing at all outside the state directory" \
  "$tc_before" "$(ls -1A "$TMPDIR")"

# Stop can fire for a session whose state was already cleared, or swept.
fresh
tc_base="$(ct_state_file "tc-absent")"
asserts "turn close: a session with no state file returns 0" \
  ct_turn_close "tc-absent" "$(date +%s)"
refutes "turn close: and closes nothing" test -e "$tc_base.closed"

# The state file is a file on disk, so it can be truncated or half-written.
# Both read as a start of 0, which is not a turn: nothing is closed and nothing
# is banked, rather than a turn dated from the epoch.
fresh
tc_base="$(ct_state_file "tc-corrupt")"
printf 'garbage' > "$tc_base"
ct_turn_close "tc-corrupt" "$(date +%s)"
refutes "turn close: a corrupt start writes no .closed" test -e "$tc_base.closed"
is "turn close: and banks nothing" "0" "$(ct_read_counter "$tc_base.wait")"
: > "$tc_base"
ct_turn_close "tc-corrupt" "$(date +%s)"
refutes "turn close: an empty start writes no .closed" test -e "$tc_base.closed"
is "turn close: and banks nothing either" "0" "$(ct_read_counter "$tc_base.wait")"

# /tmp is swept periodically, so the state directory can vanish under a live
# session. Closing does not call ct_state_ready, unlike ct_turn_open: a close
# with nowhere to write is dropped, rather than resurrecting a directory whose
# contents are gone anyway.
fresh
tc_base="$(ct_state_file "tc-sweep")"
printf '%s' "$(( $(date +%s) - 10 ))" > "$tc_base"
rm -rf "$(ct_state_dir)"
asserts "turn close: a swept state directory still returns 0" \
  ct_turn_close "tc-sweep" "$(date +%s)"
is "turn close: and the close does not recreate it" "0" \
  "$([ -d "$(ct_state_dir)" ] && echo 1 || echo 0)"

# The guard the three call sites depend on. Each invokes this as a bare
# statement under `set -euo pipefail`, where one non-zero return kills the hook
# and the plugin goes silent with nothing reported. Asserted in a real errexit
# shell, because this suite deliberately runs without -e and so cannot observe
# it here.
# shellcheck disable=SC2016  # $1 is for the inner bash, not this one
is "turn close: an unusable id does not abort an errexit hook" "ok" \
  "$(env bash -c '
       set -euo pipefail
       . "$1/lib/config.sh"; . "$1/lib/state.sh"
       ct_turn_close "" 1
       ct_turn_close "///" 1
       echo ok
     ' _ "$SCRIPTS" 2>/dev/null)"
# shellcheck disable=SC2016  # $1 is for the inner bash, not this one
is "turn close: nor does a session with nothing to close" "ok" \
  "$(env bash -c '
       set -euo pipefail
       . "$1/lib/config.sh"; . "$1/lib/state.sh"
       ct_turn_close "tc-errexit" 1
       echo ok
     ' _ "$SCRIPTS" 2>/dev/null)"

# The wrapper is ct_close_turn with the path resolved for it, and the two must
# not drift into disagreeing about the same turn. One clock reading feeds both
# sides, so the comparison is about the code rather than the second it ran in,
# and the banked figure is pinned as well as compared -- two zeroes would agree
# with each other while proving nothing.
fresh
tc_now="$(date +%s)"
tc_a="$(ct_state_file "tcpar-a")"
tc_b="$(ct_state_file "tcpar-b")"
printf '%s' "$(( tc_now - 65 ))" > "$tc_a"
printf '%s' "$(( tc_now - 65 ))" > "$tc_b"
ct_turn_close "tcpar-a" "$tc_now"
ct_close_turn "$tc_b" "$tc_now"
is "turn close: banks the turn's whole cost" "65" "$(ct_read_counter "$tc_a.wait")"
is "turn close: parity with ct_close_turn on the total" \
  "$(ct_read_counter "$tc_b.wait")" "$(ct_read_counter "$tc_a.wait")"
is "turn close: parity with ct_close_turn on the close time" \
  "$(ct_read_counter "$tc_b.closed")" "$(ct_read_counter "$tc_a.closed")"

# A session is many turns and .wait is the running total across all of them.
# Reopening is what user-prompt-submit.sh does -- restamp the start, drop the
# .closed sibling -- and the next close has to add to what is banked rather
# than replace it.
fresh
tc_now="$(date +%s)"
tc_base="$(ct_state_file "tc-acc")"
printf '%s' "$(( tc_now - 10 ))" > "$tc_base"
ct_turn_close "tc-acc" "$tc_now"
is "turn close: the first turn banks its own cost" "10" \
  "$(ct_read_counter "$tc_base.wait")"
rm -f "$tc_base.closed"
printf '%s' "$(( tc_now - 30 ))" > "$tc_base"
ct_turn_close "tc-acc" "$tc_now"
is "turn close: a reopened turn adds to the total rather than replacing it" "40" \
  "$(ct_read_counter "$tc_base.wait")"

echo
echo "atomic config writes"

# Both config writers -- write_config and write_project_config -- pipe the file
# they have built into _ct_write_atomic, which builds it beside the target and
# renames over it. Lift just that function out of setup.sh: the file ends in
# `main "$@"`, so sourcing it would run the whole wizard. Same trick the
# display-width cases above use for _ct_display_width.
eval "$(sed -n '/^_ct_write_atomic() {$/,/^}$/p' "$SCRIPTS/setup.sh")"

# The temp file is named "$file.$$", so two writers get distinct temps only
# when they are distinct PROCESSES -- a subshell inherits $$. The racing case
# at the end therefore needs real second and third processes, and this runner
# is one. It doubles as the way to observe a failing return code without the
# error path's diagnostics landing in the suite's own output.
wa_runner="$WORK/write-atomic-runner.sh"
{
  echo '#!/usr/bin/env bash'
  sed -n '/^_ct_write_atomic() {$/,/^}$/p' "$SCRIPTS/setup.sh"
  # shellcheck disable=SC2016  # $1 is for the generated script to expand, not
  # for this one.
  echo '_ct_write_atomic "$1"'
} > "$wa_runner"

WA="$WORK/atomic"
rm -rf "$WA"; mkdir -p "$WA"

# Whatever arrives on stdin is what lands. The byte count is asserted next to
# the text because `$(cat ...)` eats trailing newlines: a writer that appended
# one of its own would still satisfy the text comparison alone, and the config
# file is read back by a parser that is sensitive to what its last line is.
printf '%s\n' 'COLOR=cyan' 'TZ=Asia/Tokyo' | _ct_write_atomic "$WA/new.conf"
is "atomic write: a new file reports success" "0" "$?"
is "atomic write: stdin lands verbatim" "COLOR=cyan
TZ=Asia/Tokyo" "$(cat "$WA/new.conf")"
is "atomic write: and nothing is added to it" "25" \
   "$(LC_ALL=C wc -c < "$WA/new.conf" | tr -d ' ')"

# The property this function exists for, and the reason the config writers do
# not simply redirect over the target: ct_load_config reads the config from
# five hooks and message-display reads it on every displayed message, so a
# reader can be holding the file open across a write. Rename swaps the
# directory entry, so that reader keeps the whole OLD file rather than watching
# its own file shrink to nothing. Written the same way the --project case at
# the top of "writing a project config" does it.
printf '%s\n' 'COLOR=cyan' > "$WA/live.conf"
exec 9< "$WA/live.conf"
printf '%s\n' 'COLOR=green' 'MARKER=%time' | _ct_write_atomic "$WA/live.conf"
wa_open="$(cat <&9)"
exec 9<&-
is "atomic write: a reader holding the old file still reads it whole" "COLOR=cyan" "$wa_open"
is "atomic write: while the path now names the new file" "COLOR=green
MARKER=%time" "$(cat "$WA/live.conf")"

# The temp is an implementation detail and must not outlive the call. One left
# behind in ~/.claude is litter the user has to explain to themselves, and one
# left behind next to a project config would be committed.
# Asked as the glob the contract names -- "$file".* -- rather than by parsing
# ls, so a temp with a space or a newline in its name is still caught. With
# nullglob off an unmatched pattern comes back as itself, which is what the
# -e guard is for.
wa_left=""
for wa_f in "$WA"/*.conf.*; do
  [ -e "$wa_f" ] && wa_left="$wa_left ${wa_f##*/}"
done
is "atomic write: no temp file survives a success" "" "${wa_left# }"

# An empty payload is a file, not a no-op. write_project_config refuses to call
# this with nothing to write, but the account writer has no such guard, and
# "the file was left alone" and "the file was emptied" are different states for
# a loader that treats a missing file as "not configured yet".
printf '' | _ct_write_atomic "$WA/empty.conf"
is "atomic write: empty stdin reports success" "0" "$?"
asserts "atomic write: empty stdin still creates the target" test -f "$WA/empty.conf"
is "atomic write: and the target is zero bytes" "0" \
   "$(LC_ALL=C wc -c < "$WA/empty.conf" | tr -d ' ')"

# write_project_config ends with `printf '%s' "$out"`, so whether the file ends
# in a newline is decided by the caller. This function may not decide it: the
# length pins that nothing was appended, the text pins that nothing was lost.
printf 'COLOR=cyan' | _ct_write_atomic "$WA/nonl.conf"
is "atomic write: a payload with no trailing newline keeps its length" "10" \
   "$(LC_ALL=C wc -c < "$WA/nonl.conf" | tr -d ' ')"
is "atomic write: and keeps its content" "COLOR=cyan" "$(cat "$WA/nonl.conf")"

# The temp is created beside the target on purpose -- a rename across
# filesystems is not atomic -- which means a target whose parent is missing
# cannot be staged anywhere. That has to be a clean failure, not a half-written
# file somewhere else.
rm -rf "$WA/absent"
printf '%s\n' 'COLOR=cyan' | bash "$wa_runner" "$WA/absent/sub.conf" 2>/dev/null
is "atomic write: a missing parent directory returns 1" "1" "$?"
refutes "atomic write: and nothing is created on the way" test -e "$WA/absent"

# A read-only parent is the realistic version of the same failure: the config
# directory exists but the write cannot land. The contract is that the target
# is left exactly as it was and the temp is cleaned up, so a failed
# `/timestamps` leaves a working config rather than an empty one.
#
# Root ignores the mode bits entirely -- checked: the write succeeds as root --
# so this needs an unprivileged user and a filesystem that has mode bits at all.
if [ "$(id -u)" != "0" ] && [ "$CT_HAS_MODES" = "1" ]; then
  rm -rf "$WA/ro"; mkdir -p "$WA/ro"
  printf '%s\n' 'COLOR=cyan' > "$WA/ro/keep.conf"
  chmod 500 "$WA/ro"
  printf '%s\n' 'COLOR=green' | bash "$wa_runner" "$WA/ro/keep.conf" 2>/dev/null
  is "atomic write: an unwritable parent directory returns 1" "1" "$?"
  chmod 700 "$WA/ro"
  is "atomic write: and the target keeps what it had" "COLOR=cyan" "$(cat "$WA/ro/keep.conf")"
  wa_left=""
  for wa_f in "$WA/ro"/*.conf.*; do
    [ -e "$wa_f" ] && wa_left="$wa_left ${wa_f##*/}"
  done
  is "atomic write: and no temp is left behind by the failure" "" "${wa_left# }"
  rm -rf "$WA/ro"
else
  skip "atomic write: an unwritable parent directory returns 1" \
       "root ignores the mode bits, so this needs an unprivileged user"
  skip "atomic write: and the target keeps what it had" \
       "root ignores the mode bits, so this needs an unprivileged user"
  skip "atomic write: and no temp is left behind by the failure" \
       "root ignores the mode bits, so this needs an unprivileged user"
fi

# `mv` replaces the NAME, so an unresolved symlinked target is replaced by a
# regular file and the file it pointed at keeps the old settings. Symlinking
# ~/.claude/claude-timestamp.conf into a dotfiles repository is the ordinary
# way to version a config, and this detaches it silently: the wizard reports
# success, the repository never changes, and the next `stow`-style relink
# throws the new settings away, so the write has to resolve the link first.
if [ "$CT_HAS_SYMLINKS" = "1" ]; then
  rm -rf "$WA/link"; mkdir -p "$WA/link"
  printf '%s\n' 'COLOR=cyan' > "$WA/link/real.conf"
  ln -s "$WA/link/real.conf" "$WA/link/alias.conf"
  printf '%s\n' 'COLOR=green' | _ct_write_atomic "$WA/link/alias.conf"
  asserts "atomic write: a symlinked target stays a symlink" \
          test -L "$WA/link/alias.conf"
  is "atomic write: and the file it points at receives the new content" \
     "COLOR=green" "$(cat "$WA/link/real.conf")"

  # A relative target is relative to the directory the link sits in, not to the
  # working directory the wizard happens to be run from. Resolving it against
  # the wrong one writes a new file next to the caller and leaves the config
  # untouched, which looks exactly like success.
  rm -rf "$WA/link"; mkdir -p "$WA/link/inner"
  printf '%s\n' 'COLOR=cyan' > "$WA/link/inner/real.conf"
  ln -s real.conf "$WA/link/inner/alias.conf"
  ( cd "$WA" && printf '%s\n' 'COLOR=green' | _ct_write_atomic "link/inner/alias.conf" )
  asserts "atomic write: a relative link stays a symlink" \
          test -L "$WA/link/inner/alias.conf"
  is "atomic write: and resolves against the link's own directory" \
     "COLOR=green" "$(cat "$WA/link/inner/real.conf")"
  refutes "atomic write: and writes nothing beside the caller" \
          test -e "$WA/real.conf"

  # A chain has to be followed to its end. Stopping one hop in would write the
  # middle link, replacing it and detaching the rest of the chain.
  rm -rf "$WA/link"; mkdir -p "$WA/link"
  printf '%s\n' 'COLOR=cyan' > "$WA/link/real.conf"
  ln -s real.conf  "$WA/link/mid.conf"
  ln -s mid.conf   "$WA/link/alias.conf"
  printf '%s\n' 'COLOR=green' | _ct_write_atomic "$WA/link/alias.conf"
  is "atomic write: a chain of links reaches the file at the end" \
     "COLOR=green" "$(cat "$WA/link/real.conf")"
  asserts "atomic write: and every link in the chain survives" \
          test -L "$WA/link/alias.conf" -a -L "$WA/link/mid.conf"

  # A loop never reaches a real file. Writing at the point the walk gives up
  # would replace whichever link it stopped on, so it is refused instead.
  rm -rf "$WA/link"; mkdir -p "$WA/link"
  ln -s b.conf "$WA/link/a.conf"
  ln -s a.conf "$WA/link/b.conf"
  # The status is captured from the function itself rather than through a
  # `refutes` helper running it in `sh`, where the function does not exist and
  # a command-not-found would satisfy the assertion without ever calling it.
  if printf 'x\n' | _ct_write_atomic "$WA/link/a.conf"; then wa_loop_rc=0; else wa_loop_rc=1; fi
  is "atomic write: a symlink loop returns 1" "1" "$wa_loop_rc"
  asserts "atomic write: and leaves the loop as it found it" \
          test -L "$WA/link/a.conf" -a -L "$WA/link/b.conf"
  is "atomic write: and leaves no temp behind" "a.conf b.conf" \
     "$(ls -1A "$WA/link" | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
  rm -rf "$WA/link"
else
  skip "atomic write: a symlinked target is written through, not replaced" "needs real symlinks"
fi

# Two wizards finishing at once -- two terminals, or a hook and a hand-run
# `/timestamps`. Whoever renames last wins, and that is fine; what may never
# happen is a survivor built from both. Repeated, because a single round would
# pass even on a writer that truncates in place and simply got lucky.
rm -rf "$WA/race"; mkdir -p "$WA/race"
wa_race="$WA/race/config.conf"
wa_a="ENABLED=on
COLOR=cyan
TZ=Asia/Tokyo
MARKER=%time"
wa_b="ENABLED=off
COLOR=green
TZ=Europe/Paris
MARKER=%date"
wa_torn=""
wa_lost=""
for wa_round in 1 2 3 4 5 6 7 8; do
  printf '%s' "$wa_a" | bash "$wa_runner" "$wa_race" 2>/dev/null &
  wa_p1=$!
  printf '%s' "$wa_b" | bash "$wa_runner" "$wa_race" 2>/dev/null &
  wa_p2=$!
  wait "$wa_p1"; wait "$wa_p2"
  wa_got="$(cat "$wa_race")"
  for wa_key in ENABLED COLOR TZ MARKER; do
    case "$wa_got" in
      *"$wa_key="*) ;;
      *) wa_lost="$wa_lost round$wa_round:$wa_key" ;;
    esac
  done
  case "$wa_got" in
    "$wa_a"|"$wa_b") ;;
    *) wa_torn="$wa_torn round$wa_round" ;;
  esac
done
is "atomic write: a raced target still carries every key" "" "$wa_lost"
is "atomic write: and is exactly one writer's file, never a blend" "" "$wa_torn"
rm -rf "$WA"

echo "project naming"

proj="$WORK/proj-$$"
mkdir -p "$proj/repo/deep/deeper/.keep" "$proj/repo/.git" "$proj/loose/sub"

is "project: a repository root is named after itself" \
   "repo" "$(ct_project_name "$proj/repo")"
is "project: a directory inside a repository takes the repository's name" \
   "repo" "$(ct_project_name "$proj/repo/deep/deeper")"
is "project: an empty cwd is unnamed" \
   "-" "$(ct_project_name "")"
is "project: the filesystem root is unnamed" \
   "-" "$(ct_project_name "/")"

# A slash-free argument makes "${dir%/*}" a no-op, which used to leave the
# walk re-testing the same directory on every one of its 40 steps instead of
# recognising at once that there is nowhere left to shorten to.
is "project: a slash-free input still resolves correctly" \
   "no-such-project-xyz123" "$(ct_project_name "no-such-project-xyz123")"

# The assertion above passes either way -- the walk was always bounded and
# always fell through to the same right answer, slash-free path or not. What
# changed is how many times it tested the same directory on the way there.
# Traced by counting how often the loop actually tests "-d .../.git", the
# only way to observe that from outside the function: 40 times before this
# fix (one per step, since the path never got any shorter), once after.
pn_walk_steps="$(bash -c '
  source "'"$SCRIPTS"'/lib/config.sh"
  set -x
  ct_project_name "no-such-project-xyz123" >/dev/null
' 2>&1 | grep -c -- "-d no-such-project-xyz123/.git")"
is "project: a slash-free input no longer spins through all 40 steps" \
   "1" "$pn_walk_steps"

# A directory name may legally contain a tab or a newline (mkdir does not
# reject either), and either would corrupt a history row: a tab forges an
# extra field, a newline splits the row into two lines. The character sits in
# the MIDDLE of the basename here, not at the end -- $(...) strips a trailing
# newline regardless of whether the fix ran, which would let a broken
# implementation pass this assertion for the wrong reason.
tab_repo="tab"$'\t'"repo"
nl_repo="nl"$'\n'"repo"
mkdir -p "$proj/$tab_repo/.git" "$proj/$nl_repo/.git"
is "project: a tab in the directory name becomes an underscore" \
   "tab_repo" "$(ct_project_name "$proj/$tab_repo")"
is "project: a newline in the directory name becomes an underscore" \
   "nl_repo" "$(ct_project_name "$proj/$nl_repo")"

# The two fallback cases below need no repository ANYWHERE above the fixture,
# and that is a property of wherever TMPDIR points rather than of anything this
# suite controls. Under a TMPDIR inside a checkout the walk correctly finds
# that checkout, and the assertions would fail for a reason that has nothing to
# do with the code. Checked, and skipped rather than asserted when the
# environment cannot answer, which is what skip() exists for.
pn_clean=1
pn_dir="$proj"
while [ -n "$pn_dir" ] && [ "$pn_dir" != "/" ]; do
  if [ -d "$pn_dir/.git" ] || [ -f "$pn_dir/.git" ]; then pn_clean=0; break; fi
  pn_dir="${pn_dir%/*}"
done
if [ "$pn_clean" -eq 1 ]; then
  is "project: no repository above falls back to the directory itself" \
     "sub" "$(ct_project_name "$proj/loose/sub")"
  is "project: a cwd that does not exist still yields its own basename" \
     "gone" "$(ct_project_name "$proj/gone")"
else
  skip "project: no repository above falls back to the directory itself" \
       "TMPDIR is inside a git repository, so there is always one above"
  skip "project: a cwd that does not exist still yields its own basename" \
       "TMPDIR is inside a git repository, so there is always one above"
fi

rm -rf "$proj"

echo "tool digest"

log="$WORK/digest.log"
# The log's own writer, post-tool-use.sh, emits space-separated lines --
# "<tool name> <seconds> <outcome>" -- so every fixture here uses that format
# too. See the end-to-end case below, which drives the writer itself instead
# of fabricating its output, so this suite cannot drift past the real format
# again the way it did before.
printf 'Bash 12.500 ok\nRead 0.250 ok\nBash 7.500 ok\n' > "$log"
is "digest: sums per tool and sorts worst first" \
   "Bash:20:2,Read:0:1" "$(ct_tool_digest "$log")"

printf 'Weird,Name 3.000 ok\nOther:Tool 2.000 ok\n' > "$log"
is "digest: a separator inside a tool name is neutralised" \
   "Weird_Name:3:1,Other_Tool:2:1" "$(ct_tool_digest "$log")"

# post-tool-use.sh sanitises any tool name with a byte outside [A-Za-z0-9_-]
# to "unknown" before it ever reaches the log, and awk's default field
# splitting treats a tab the same as a space, so a raw tab can never actually
# land inside field 1 either way. The gsub covers it anyway, as a second line
# of defense against a future writer that relaxes that guard. Under the
# default separator, field splitting has already consumed the tab by the time
# gsub runs, so this fixture cannot actually exercise the \t branch of that
# gsub -- $1 is already just "Tabbed" before gsub sees it. The \t stays in the
# character class regardless, for a future where the separator or the writer
# changes and that branch becomes reachable.
printf 'Tabbed\tName 4.000 ok\n' > "$log"
refutes "digest: a tab cannot leak a second field into the digest" \
        grep -q $'\t' <<< "$(ct_tool_digest "$log")"

: > "$log"
is "digest: an empty log yields nothing" "" "$(ct_tool_digest "$log")"
is "digest: a missing log yields nothing" "" "$(ct_tool_digest "$WORK/no-such-log")"

: > "$log"
for i in 1 2 3 4 5 6 7 8 9 10; do printf 'T%s %s.000 ok\n' "$i" "$i" >> "$log"; done
is "digest: keeps at most eight tools" \
   "8" "$(ct_tool_digest "$log" | awk -F',' '{print NF}')"
is "digest: and keeps the costliest ones" \
   "T10:10:1" "$(ct_tool_digest "$log" | cut -d, -f1)"

printf 'Bash not-a-number ok\n' > "$log"
is "digest: a row with no usable duration contributes nothing" \
   "Bash:0:1" "$(ct_tool_digest "$log")"

if command -v jq >/dev/null 2>&1; then
  # End to end: drive the real writer, post-tool-use.sh, instead of
  # fabricating its output. This is the case that would have caught the
  # space-vs-tab mismatch on its own, and is meant to keep catching it if the
  # writer's format ever changes again.
  fresh 'TOOL_TIMING=on'
  ct_stage_flag "digest-e2e" "timing-on" "1"
  printf '{"session_id":"digest-e2e","tool_use_id":"d1","tool_name":"Bash","duration_ms":12500}' \
    | bash "$SCRIPTS/post-tool-use.sh"
  printf '{"session_id":"digest-e2e","tool_use_id":"d2","tool_name":"Bash","duration_ms":7500}' \
    | bash "$SCRIPTS/post-tool-use.sh"
  printf '{"session_id":"digest-e2e","tool_use_id":"d3","tool_name":"Read","duration_ms":250}' \
    | bash "$SCRIPTS/post-tool-use.sh"
  is "digest: reads the log post-tool-use.sh actually writes" \
     "Bash:20:2,Read:0:1" "$(ct_tool_digest "$(ct_tool_log digest-e2e)")"
else
  skip "digest: reads the log post-tool-use.sh actually writes" "jq not installed"
fi

echo "history columns at session end"

hc_run() {  # hc_run <config lines> ; plants one turn and ends the session
  local sid="hc-$$-$RANDOM"
  printf '%s\n' "$1" > "$CLAUDE_TIMESTAMP_CONFIG"
  : > "$CLAUDE_TIMESTAMP_HISTORY"
  local sf; sf="$(ct_state_file "$sid")"
  printf '%s' "$(( $(date +%s) - 100 ))" > "${sf}.start"
  printf '1'   > "${sf}.turns"
  printf '40'  > "${sf}.wait"
  printf '0'   > "${sf}.idle"
  printf 'Bash 12.500 ok\nRead 0.250 ok\n' > "${sf}.tools"
  printf '{"session_id":"%s","cwd":"%s"}' "$sid" "$2" \
    | bash "$SCRIPTS/session-end.sh" >/dev/null 2>&1
}

hc_repo="$WORK/hc-repo"
mkdir -p "$hc_repo/.git"

hc_run "PROJECTS=off"$'\n'"TOOL_TIMING=off" "$hc_repo"
is "columns: both off writes six fields" \
   "6" "$(awk -F'\t' 'NR==1{print NF}' "$CLAUDE_TIMESTAMP_HISTORY")"

hc_run "PROJECTS=on"$'\n'"TOOL_TIMING=off" "$hc_repo"
is "columns: PROJECTS on writes the project" \
   "hc-repo" "$(cut -f7 "$CLAUDE_TIMESTAMP_HISTORY")"

hc_run "PROJECTS=off"$'\n'"TOOL_TIMING=on" "$hc_repo"
is "columns: TOOL_TIMING on writes the digest" \
   "Bash:12:1,Read:0:1" "$(cut -f8 "$CLAUDE_TIMESTAMP_HISTORY")"
is "columns: with no project recorded beside it" \
   "-" "$(cut -f7 "$CLAUDE_TIMESTAMP_HISTORY")"

# The regression at state.sh:402, in the one place it can come back.
hc_run "SUMMARY=off"$'\n'"TOOL_TIMING=on"$'\n'"PROJECTS=on" "$hc_repo"
is "columns: SUMMARY=off still records the row" \
   "1" "$(wc -l < "$CLAUDE_TIMESTAMP_HISTORY" | tr -d ' ')"
is "columns: and still records the tool digest" \
   "Bash:12:1,Read:0:1" "$(cut -f8 "$CLAUDE_TIMESTAMP_HISTORY")"

hc_run "PROJECTS=on"$'\n'"TOOL_TIMING=on"$'\n'"HISTORY=off" "$hc_repo"
is "columns: HISTORY=off records nothing at all" \
   "0" "$(wc -c < "$CLAUDE_TIMESTAMP_HISTORY" | tr -d ' ')"

# A tool log with enough distinct tools makes `ct_tool_digest`'s internal
# `sort -rn | head -8` close its pipe on `sort` before `sort` is done writing,
# which sends `sort` SIGPIPE. Under session-end.sh's errexit/pipefail, a
# nonzero exit from that pipeline used to abort the hook right there --
# before ct_history_append and before ct_clear_state ran -- losing the
# session's record and stranding its state files. 2000 distinct tools is
# enough to reproduce it.
big_sid="hc-big-$$-$RANDOM"
printf '%s\n' "TOOL_TIMING=on" > "$CLAUDE_TIMESTAMP_CONFIG"
: > "$CLAUDE_TIMESTAMP_HISTORY"
big_sf="$(ct_state_file "$big_sid")"
printf '%s' "$(( $(date +%s) - 100 ))" > "${big_sf}.start"
printf '1'  > "${big_sf}.turns"
printf '40' > "${big_sf}.wait"
printf '0'  > "${big_sf}.idle"
awk 'BEGIN { for (i = 0; i < 2000; i++) printf "Tool%04d 0.001 ok\n", i }' > "${big_sf}.tools"
printf '{"session_id":"%s","cwd":"%s"}' "$big_sid" "$hc_repo" \
  | bash "$SCRIPTS/session-end.sh" >/dev/null 2>&1
big_status=$?
is "large log: session-end still exits 0" "0" "$big_status"
is "large log: the history row is still written" \
   "1" "$(wc -l < "$CLAUDE_TIMESTAMP_HISTORY" | tr -d ' ')"
if [ -e "$big_sf" ] || [ -e "${big_sf}.tools" ] || [ -e "${big_sf}.start" ]; then
  fail "large log: session state is still cleared" "no state files left" "state files remain"
else
  pass "large log: session state is still cleared"
fi

rm -rf "$hc_repo"

echo
echo "----"
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
