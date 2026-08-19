#!/usr/bin/env bash
# Test suite for claude-timestamp. Plain bash, no framework, no dependencies
# beyond what the plugin itself already needs.
#
#   bash tests/run.sh
#
# Every test runs against a temp config file via CLAUDE_TIMESTAMP_CONFIG and a
# temp TMPDIR, so a run never touches the real configuration or state.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
mkdir -p "$TMPDIR"
export CLAUDE_TIMESTAMP_CONFIG="$WORK/config.conf"

source "$SCRIPTS/lib/config.sh"

echo
echo "config parsing"

: > "$CLAUDE_TIMESTAMP_CONFIG"
ct_load_config
is "defaults: display format" "24h" "$CT_DISPLAY_FORMAT"
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

printf 'TZ=Europe/Paris\r\nCOLOR=blue\r\n' > "$CLAUDE_TIMESTAMP_CONFIG"
ct_load_config
is "tolerates CRLF line endings" "Europe/Paris" "$CT_TZ"

printf 'COLOR=green' > "$CLAUDE_TIMESTAMP_CONFIG"
ct_load_config
is "reads a final line with no trailing newline" "green" "$CT_COLOR"

# The config file is parsed, never sourced. If it were sourced, this would
# create the file named in the substitution.
# shellcheck disable=SC2016  # the literal $(..) is exactly what is being tested
printf 'COLOR=$(touch %s/pwned)\n' "$WORK" > "$CLAUDE_TIMESTAMP_CONFIG"
ct_load_config
if [ -e "$WORK/pwned" ]; then fail "config file cannot execute code" "no file created" "command ran"; else pass "config file cannot execute code"; fi

echo
echo "format presets"

is "24h preset"   '%H:%M:%S'           "$(ct_expand_format 24h)"
is "short preset" '%H:%M'              "$(ct_expand_format short)"
is "12h preset"   '%I:%M %p'           "$(ct_expand_format 12h)"
is "iso preset"   '%Y-%m-%dT%H:%M:%S'  "$(ct_expand_format iso)"
is "raw strftime passes through" '%A %H:%M' "$(ct_expand_format '%A %H:%M')"
is "unknown preset falls back to 24h" '%H:%M:%S' "$(ct_expand_format nonsense)"

: > "$CLAUDE_TIMESTAMP_CONFIG"
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

: > "$CLAUDE_TIMESTAMP_CONFIG"
ct_load_config
CT_TZ="Asia/Tokyo"

# CT_TZ_SUPPORTED is read by the sourced library, which shellcheck cannot see.
# shellcheck disable=SC2034
# Simulate a platform without a timezone database (Git Bash on Windows) by
# priming the memoised probe, and assert the pinned zone is ignored rather
# than rendered as UTC.
CT_TZ_SUPPORTED="no"
is "an unhonourable zone falls back to local time" "$(date '+%H:%M')" "$(ct_now short)"
if ct_tz_unhonoured; then pass "a pinned but unsupported zone is reported"; else fail "a pinned but unsupported zone is reported" "true" "false"; fi

# shellcheck disable=SC2034  # read by the sourced library
CT_TZ_SUPPORTED="yes"
if ct_tz_supported; then
  is "a supported zone is applied" "$(TZ=Asia/Tokyo date '+%H:%M')" "$(ct_now short)"
else
  echo "  skip a supported zone is applied (no timezone database)"
fi
CT_TZ="UTC"
is "UTC is honoured with or without a timezone database" "$(TZ=UTC date '+%H:%M')" "$(ct_now short)"

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

echo
echo "color"

contains "dim emits an ANSI sequence" "[2m" "$(ct_color_start dim)"
is "none emits nothing" "" "$(ct_color_start none)"
is "unknown color emits nothing" "" "$(ct_color_start banana)"
is "no reset when there was no color" "" "$(ct_color_end none)"
contains "reset follows a real color" "[0m" "$(ct_color_end dim)"
is "NO_COLOR disables color" "" "$(NO_COLOR=1 ct_color_start dim)"

echo
echo "hooks"

if command -v jq >/dev/null 2>&1; then
  : > "$CLAUDE_TIMESTAMP_CONFIG"

  out="$(printf '{"session_id":"test-session","index":0,"delta":"Hello there."}' | bash "$SCRIPTS/message-display.sh")"
  contains "message-display stamps index 0" "displayContent" "$out"
  contains "message-display keeps the original text" "Hello there." "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.displayContent')"

  out="$(printf '{"session_id":"test-session","index":3,"delta":"more text"}' | bash "$SCRIPTS/message-display.sh")"
  is "message-display emits nothing for later batches" "" "$out"

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

  printf 'ELAPSED=off\n' > "$CLAUDE_TIMESTAMP_CONFIG"
  out="$(printf '{"session_id":"test-session","index":0,"delta":"x"}' | bash "$SCRIPTS/message-display.sh" | jq -r '.hookSpecificOutput.displayContent')"
  case "$out" in *"+"*) fail "ELAPSED=off hides the duration" "no + marker" "$out" ;; *) pass "ELAPSED=off hides the duration" ;; esac

  # Date rollover: a stale date on file means the session crossed midnight.
  printf 'COLOR=none\nELAPSED=off\n' > "$CLAUDE_TIMESTAMP_CONFIG"
  printf '2000-01-01' > "$(ct_state_dir)/test-session.date"
  out="$(printf '{"session_id":"test-session","index":0,"delta":"x"}' | bash "$SCRIPTS/message-display.sh" | jq -r '.hookSpecificOutput.displayContent')"
  contains "date rollover adds the date after midnight" "$(date '+%b %d')" "$out"

  # The hook just recorded today, so a second message must not repeat it.
  # Asserted as the absence of a month name rather than by recomputing the
  # clock, which races with the hook by a second on a slow runner.
  out="$(printf '{"session_id":"test-session","index":0,"delta":"x"}' | bash "$SCRIPTS/message-display.sh" | jq -r '.hookSpecificOutput.displayContent')"
  lacks "date is not repeated on the same day" "$(date '+%b')" "$out"

  printf 'COLOR=none\nELAPSED=off\nDATE_ROLLOVER=off\n' > "$CLAUDE_TIMESTAMP_CONFIG"
  printf '2000-01-01' > "$(ct_state_dir)/test-session.date"
  out="$(printf '{"session_id":"test-session","index":0,"delta":"x"}' | bash "$SCRIPTS/message-display.sh" | jq -r '.hookSpecificOutput.displayContent')"
  lacks "DATE_ROLLOVER=off suppresses the date" "$(date '+%b')" "$out"

  # Slow-turn colouring: the duration alone is painted, the rest is not.
  printf 'COLOR=none\nSLOW_AFTER=60\nSLOW_COLOR=cyan\nIDLE_AFTER=0\nDATE_ROLLOVER=off\n' > "$CLAUDE_TIMESTAMP_CONFIG"
  printf '%s' "$(( $(date +%s) - 3780 ))" > "$(ct_state_dir)/test-session"
  out="$(printf '{"session_id":"test-session","index":0,"delta":"x"}' | bash "$SCRIPTS/message-display.sh" | jq -r '.hookSpecificOutput.displayContent')"
  contains "a slow turn paints the duration" "[36m" "$out"

  printf 'COLOR=none\nSLOW_AFTER=0\nIDLE_AFTER=0\nDATE_ROLLOVER=off\n' > "$CLAUDE_TIMESTAMP_CONFIG"
  printf '%s' "$(( $(date +%s) - 3780 ))" > "$(ct_state_dir)/test-session"
  out="$(printf '{"session_id":"test-session","index":0,"delta":"x"}' | bash "$SCRIPTS/message-display.sh" | jq -r '.hookSpecificOutput.displayContent')"
  lacks "SLOW_AFTER=0 leaves the duration unpainted" "[36m" "$out"

  printf 'COLOR=none\nSLOW_AFTER=99999\nIDLE_AFTER=0\nDATE_ROLLOVER=off\n' > "$CLAUDE_TIMESTAMP_CONFIG"
  printf '%s' "$(( $(date +%s) - 3780 ))" > "$(ct_state_dir)/test-session"
  out="$(printf '{"session_id":"test-session","index":0,"delta":"x"}' | bash "$SCRIPTS/message-display.sh" | jq -r '.hookSpecificOutput.displayContent')"
  lacks "a turn under the threshold is unpainted" "[36m" "$out"

  # Idle divider.
  printf 'COLOR=none\nELAPSED=off\nIDLE_AFTER=3600\nDATE_ROLLOVER=off\n' > "$CLAUDE_TIMESTAMP_CONFIG"
  printf '%s' "$(( $(date +%s) - 7200 ))" > "$(ct_state_dir)/test-session.last"
  out="$(printf '{"session_id":"test-session","index":0,"delta":"x"}' | bash "$SCRIPTS/message-display.sh" | jq -r '.hookSpecificOutput.displayContent')"
  contains "an idle gap is marked" "2h later" "$out"

  # The hook just recorded now, so the next message is not idle.
  out="$(printf '{"session_id":"test-session","index":0,"delta":"x"}' | bash "$SCRIPTS/message-display.sh" | jq -r '.hookSpecificOutput.displayContent')"
  lacks "a fresh gap is not marked" "later" "$out"

  printf 'COLOR=none\nELAPSED=off\nIDLE_AFTER=0\nDATE_ROLLOVER=off\n' > "$CLAUDE_TIMESTAMP_CONFIG"
  printf '%s' "$(( $(date +%s) - 7200 ))" > "$(ct_state_dir)/test-session.last"
  out="$(printf '{"session_id":"test-session","index":0,"delta":"x"}' | bash "$SCRIPTS/message-display.sh" | jq -r '.hookSpecificOutput.displayContent')"
  lacks "IDLE_AFTER=0 disables the marker" "later" "$out"

  # Subagents.
  printf 'COLOR=none\nSUBAGENTS=off\nIDLE_AFTER=0\n' > "$CLAUDE_TIMESTAMP_CONFIG"
  out="$(printf '{"session_id":"test-session","index":0,"delta":"x","agent_id":"sub-1"}' | bash "$SCRIPTS/message-display.sh")"
  is "SUBAGENTS=off skips subagent messages" "" "$out"
  out="$(printf '{"session_id":"test-session","index":0,"delta":"x"}' | bash "$SCRIPTS/message-display.sh")"
  contains "SUBAGENTS=off still stamps the main conversation" "displayContent" "$out"
  printf 'COLOR=none\nSUBAGENTS=on\nIDLE_AFTER=0\n' > "$CLAUDE_TIMESTAMP_CONFIG"
  out="$(printf '{"session_id":"test-session","index":0,"delta":"x","agent_id":"sub-1"}' | bash "$SCRIPTS/message-display.sh")"
  contains "SUBAGENTS=on stamps subagent messages" "displayContent" "$out"

  echo
  echo "turn accounting"

  : > "$CLAUDE_TIMESTAMP_CONFIG"
  base="$(ct_state_file "acct")"
  ct_clear_state "acct"
  mkdir -p "$(ct_state_dir)"

  # One prompt is one turn, however many messages it produces.
  printf '{"session_id":"acct"}' | bash "$SCRIPTS/user-prompt-submit.sh" >/dev/null
  is "a prompt counts one turn" "1" "$(ct_read_counter "$base.turns")"

  # Two messages in that turn, at 10s and then 25s from the prompt. Waiting
  # must end at 25s, not 35s -- elapsed is cumulative, so summing raw values
  # would report more waiting than the session lasted.
  printf '%s' "$(( $(date +%s) - 10 ))" > "$base"
  printf '{"session_id":"acct","index":0,"delta":"x"}' | bash "$SCRIPTS/message-display.sh" >/dev/null
  printf '%s' "$(( $(date +%s) - 25 ))" > "$base"
  printf '{"session_id":"acct","index":0,"delta":"x"}' | bash "$SCRIPTS/message-display.sh" >/dev/null
  # Double-counting would give roughly 10+25=35, so a two-second tolerance
  # still fails the bug while surviving a second of clock drift.
  is_near "messages in one turn are not double-counted" 25 "$(ct_read_counter "$base.wait")" 2
  is "extra messages do not add turns" "1" "$(ct_read_counter "$base.turns")"

  # A second prompt starts a fresh turn and its own waiting budget.
  printf '{"session_id":"acct"}' | bash "$SCRIPTS/user-prompt-submit.sh" >/dev/null
  is "a second prompt counts a second turn" "2" "$(ct_read_counter "$base.turns")"
  printf '%s' "$(( $(date +%s) - 5 ))" > "$base"
  printf '{"session_id":"acct","index":0,"delta":"x"}' | bash "$SCRIPTS/message-display.sh" >/dev/null
  is_near "waiting accumulates across turns" 30 "$(ct_read_counter "$base.wait")" 3
  ct_clear_state "acct"

  echo
  echo "session summary"

  : > "$CLAUDE_TIMESTAMP_CONFIG"
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

  printf 'SUMMARY=off\n' > "$CLAUDE_TIMESTAMP_CONFIG"
  printf '%s' "$(( $(date +%s) - 60 ))" > "$base.start"
  printf '2' > "$base.turns"; printf '5' > "$base.wait"
  out="$(printf '{"session_id":"summary-session"}' | bash "$SCRIPTS/session-end.sh")"
  is "SUMMARY=off reports nothing" "" "$out"

  printf 'INJECT_CONTEXT=false\n' > "$CLAUDE_TIMESTAMP_CONFIG"
  out="$(printf '{"session_id":"test-session","prompt":"hi"}' | bash "$SCRIPTS/user-prompt-submit.sh")"
  is "INJECT_CONTEXT=false injects nothing" "" "$out"

  # Everything optional is off so this asserts only on the time rendering
  # itself, independent of state left behind by earlier cases.
  printf 'COLOR=none\nDISPLAY_FORMAT=short\nTZ=UTC\nELAPSED=off\nDATE_ROLLOVER=off\nIDLE_AFTER=0\n' > "$CLAUDE_TIMESTAMP_CONFIG"
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
else
  echo "  skip jq not installed, hook tests not run"
fi

echo
echo "setup"

printf 'COLOR=dim\nTZ=UTC\n' > "$CLAUDE_TIMESTAMP_CONFIG"
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
contains "--show prints the config path" "$CLAUDE_TIMESTAMP_CONFIG" "$(bash "$SCRIPTS/setup.sh" --show)"
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

echo
echo "tool timing"

: > "$CLAUDE_TIMESTAMP_CONFIG"
is "tool timing is off by default" "off" "$(ct_load_config; printf '%s' "$CT_TOOL_TIMING")"

is "duration between two readings" "1.500" "$(ct_duration_between 10.000 11.500)"
is "a backwards clock reads as zero" "0.000" "$(ct_duration_between 20 10)"
contains "precise clock returns a number" "." "$(ct_now_precise).0"

is "tool state is keyed by tool use id" "$(ct_state_dir)/s.tool.toolu_01AB" "$(ct_tool_state_file "s" "toolu_01AB")"
is "tool use id is sanitised" "$(ct_state_dir)/s.tool.etcpasswd" "$(ct_tool_state_file "s" "../../etc/passwd")"
refutes "an empty tool use id is refused" ct_tool_state_file "s" ""

if command -v jq >/dev/null 2>&1; then
  # Disabled: the hooks must write nothing at all.
  printf 'TOOL_TIMING=off\n' > "$CLAUDE_TIMESTAMP_CONFIG"
  printf '{"session_id":"tools","tool_use_id":"t1","tool_name":"Bash"}' | bash "$SCRIPTS/pre-tool-use.sh"
  if [ -e "$(ct_state_dir)/tools.tool.t1" ]; then
    fail "TOOL_TIMING=off records nothing" "no state file" "file created"
  else
    pass "TOOL_TIMING=off records nothing"
  fi

  printf 'TOOL_TIMING=on\n' > "$CLAUDE_TIMESTAMP_CONFIG"

  # Two overlapping calls, interleaved the way parallel tool use actually runs:
  # both start before either finishes. Name-keyed state would lose one of them.
  printf '{"session_id":"tools","tool_use_id":"t1","tool_name":"Bash"}' | bash "$SCRIPTS/pre-tool-use.sh"
  printf '{"session_id":"tools","tool_use_id":"t2","tool_name":"Bash"}' | bash "$SCRIPTS/pre-tool-use.sh"
  printf '{"session_id":"tools","tool_use_id":"t3","tool_name":"Read"}' | bash "$SCRIPTS/pre-tool-use.sh"
  asserts "a started call is recorded" test -r "$(ct_state_dir)/tools.tool.t1"
  printf '{"session_id":"tools","tool_use_id":"t2","tool_name":"Bash"}' | bash "$SCRIPTS/post-tool-use.sh"
  printf '{"session_id":"tools","tool_use_id":"t1","tool_name":"Bash"}' | bash "$SCRIPTS/post-tool-use.sh"
  printf '{"session_id":"tools","tool_use_id":"t3","tool_name":"Read"}' | bash "$SCRIPTS/post-tool-use.sh"

  log="$(ct_tool_log tools)"
  is "every completed call is logged" "3" "$(wc -l < "$log" | tr -d ' ')"
  is "the log records tool names" "2" "$(grep -c '^Bash ' "$log")"
  if [ -e "$(ct_state_dir)/tools.tool.t1" ]; then
    fail "a completed call clears its start file" "no file" "file remains"
  else
    pass "a completed call clears its start file"
  fi

  # A post without a matching pre must not invent an entry.
  printf '{"session_id":"tools","tool_use_id":"never-started","tool_name":"Bash"}' | bash "$SCRIPTS/post-tool-use.sh"
  is "an unmatched completion is ignored" "3" "$(wc -l < "$log" | tr -d ' ')"

  # Aggregation in the summary.
  base="$(ct_state_file "tools")"
  printf '%s' "$(( $(date +%s) - 600 ))" > "$base.start"
  printf '2' > "$base.turns"; printf '30' > "$base.wait"
  printf 'Bash 40.0\nBash 1.2\nWebFetch 8.1\nRead 0.4\n' > "$log"
  out="$(printf '{"session_id":"tools"}' | bash "$SCRIPTS/session-end.sh" | jq -r '.systemMessage')"
  contains "the summary names the slowest tool first" "slowest tools: Bash 41.2s (2 calls)" "$out"
  contains "the summary counts a single call in the singular" "WebFetch 8.1s (1 call)" "$out"
  contains "the summary keeps the turn line too" "over 2 turns" "$out"

  printf 'TOOL_TIMING=off\n' > "$CLAUDE_TIMESTAMP_CONFIG"
  printf '%s' "$(( $(date +%s) - 600 ))" > "$base.start"
  printf '2' > "$base.turns"; printf '30' > "$base.wait"
  printf 'Bash 40.0\n' > "$log"
  out="$(printf '{"session_id":"tools"}' | bash "$SCRIPTS/session-end.sh" | jq -r '.systemMessage')"
  lacks "TOOL_TIMING=off omits the tool line" "slowest tools" "$out"
fi

echo
echo "doctor"

: > "$CLAUDE_TIMESTAMP_CONFIG"
out="$(bash "$SCRIPTS/setup.sh" --doctor)"
contains "doctor reports jq"           "jq" "$out"
contains "doctor reports the platform" "uname" "$out"
contains "doctor renders a preview"    "Preview" "$out"
contains "doctor reports no problems on a healthy setup" "No problems found" "$out"
asserts "doctor exits zero when healthy" bash "$SCRIPTS/setup.sh" --doctor

echo
echo "----"
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
