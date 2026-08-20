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
  mkdir -p "$(ct_state_dir)"
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
mkdir -p "$TMPDIR"
export CLAUDE_TIMESTAMP_CONFIG="$WORK/config.conf"
export CLAUDE_TIMESTAMP_HISTORY="$WORK/history.tsv"
export CLAUDE_TIMESTAMP_FACTS="$WORK/facts.json"

source "$SCRIPTS/lib/config.sh"

echo
echo "config parsing"

fresh
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
  fresh

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

  fresh 'ELAPSED=off'
  out="$(printf '{"session_id":"test-session","index":0,"delta":"x"}' | bash "$SCRIPTS/message-display.sh" | jq -r '.hookSpecificOutput.displayContent')"
  case "$out" in *"+"*) fail "ELAPSED=off hides the duration" "no + marker" "$out" ;; *) pass "ELAPSED=off hides the duration" ;; esac

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

  # Idle divider.
  fresh 'COLOR=none' 'ELAPSED=off' 'IDLE_AFTER=3600' 'DATE_ROLLOVER=off'
  printf '%s' "$(( $(date +%s) - 7200 ))" > "$(ct_state_dir)/test-session.last"
  out="$(printf '{"session_id":"test-session","index":0,"delta":"x"}' | bash "$SCRIPTS/message-display.sh" | jq -r '.hookSpecificOutput.displayContent')"
  contains "an idle gap is marked" "2h later" "$out"

  # The hook just recorded now, so the next message is not idle.
  out="$(printf '{"session_id":"test-session","index":0,"delta":"x"}' | bash "$SCRIPTS/message-display.sh" | jq -r '.hookSpecificOutput.displayContent')"
  lacks "a fresh gap is not marked" "later" "$out"

  fresh 'COLOR=none' 'ELAPSED=off' 'IDLE_AFTER=0' 'DATE_ROLLOVER=off'
  printf '%s' "$(( $(date +%s) - 7200 ))" > "$(ct_state_dir)/test-session.last"
  out="$(printf '{"session_id":"test-session","index":0,"delta":"x"}' | bash "$SCRIPTS/message-display.sh" | jq -r '.hookSpecificOutput.displayContent')"
  lacks "IDLE_AFTER=0 disables the marker" "later" "$out"

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
else
  echo "  skip jq not installed, hook tests not run"
fi

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

fresh
is "tool timing is off by default" "off" "$(ct_load_config; printf '%s' "$CT_TOOL_TIMING")"

is "duration between two readings" "1.500" "$(ct_duration_between 10.000 11.500)"
is "a backwards clock reads as zero" "0.000" "$(ct_duration_between 20 10)"
contains "precise clock returns a number" "." "$(ct_now_precise).0"

is "tool state is keyed by tool use id" "$(ct_state_dir)/s.tool.toolu_01AB" "$(ct_tool_state_file "s" "toolu_01AB")"
is "tool use id is sanitised" "$(ct_state_dir)/s.tool.etcpasswd" "$(ct_tool_state_file "s" "../../etc/passwd")"
refutes "an empty tool use id is refused" ct_tool_state_file "s" ""

if command -v jq >/dev/null 2>&1; then
  # Disabled: the hooks must write nothing at all.
  fresh 'TOOL_TIMING=off'
  printf '{"session_id":"tools","tool_use_id":"t1","tool_name":"Bash"}' | bash "$SCRIPTS/pre-tool-use.sh"
  if [ -e "$(ct_state_dir)/tools.tool.t1" ]; then
    fail "TOOL_TIMING=off records nothing" "no state file" "file created"
  else
    pass "TOOL_TIMING=off records nothing"
  fi

  fresh 'TOOL_TIMING=on'

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

  fresh 'TOOL_TIMING=off'
  printf '%s' "$(( $(date +%s) - 600 ))" > "$base.start"
  printf '2' > "$base.turns"; printf '30' > "$base.wait"
  printf 'Bash 40.0\n' > "$log"
  out="$(printf '{"session_id":"tools"}' | bash "$SCRIPTS/session-end.sh" | jq -r '.systemMessage')"
  lacks "TOOL_TIMING=off omits the tool line" "slowest tools" "$out"
fi

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

# Answers in prompt order: timezone, display format, elapsed, slow after, idle
# after, summary, colour, tell-Claude, write. Tool timing and context format
# are skipped because summary and tell-Claude are answered off and false.
printf '%s\nshort\non\n30\n0\noff\ncyan\nfalse\ny\n' "$tz_answer" \
  | bash "$SCRIPTS/setup.sh" >/dev/null 2>&1
ct_load_config
is "the wizard writes the timezone"   "$tz_expected" "$CT_TZ"
is "the wizard writes the format"     "short"      "$CT_DISPLAY_FORMAT"
is "the wizard writes the threshold"  "30"         "$CT_SLOW_AFTER"
is "the wizard writes the colour"     "cyan"       "$CT_COLOR"
is "the wizard writes the summary"    "off"        "$CT_SUMMARY"
is "the wizard writes the injection"  "false"      "$CT_INJECT_CONTEXT"

fresh 'COLOR=green'
printf 'local\niso\non\n0\n0\non\non\nred\ntrue\n24h\nn\n' \
  | bash "$SCRIPTS/setup.sh" >/dev/null 2>&1
ct_load_config
is "answering no writes nothing" "green" "$CT_COLOR"

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

fresh 'HISTORY_LIMIT=3'
for i in 1 2 3 4 5 6; do ct_history_append "$i" 1 0 0 0; done
is "the retention limit is applied" "3" "$(wc -l < "$CLAUDE_TIMESTAMP_HISTORY" | tr -d ' ')"
is "the newest rows are the ones kept" "6" "$(awk -F'\t' 'END{print $2}' "$CLAUDE_TIMESTAMP_HISTORY")"

fresh 'HISTORY_LIMIT=nonsense'
is "a nonsense limit falls back" "200" "$CT_HISTORY_LIMIT"

if command -v jq >/dev/null 2>&1; then
  echo
  echo "what a session adds up to"

  seed_session() {
    # $1 seconds ago it started, $2 turns, $3 waited, $4 idle, $5 failed
    local b; b="$(ct_state_file "acct2")"
    mkdir -p "$(ct_state_dir)"
    printf '%s' "$(( $(date +%s) - $1 ))" > "$b.start"
    printf '%s' "$2" > "$b.turns"
    printf '%s' "$3" > "$b.wait"
    [ "${4:-0}" -gt 0 ] && printf '%s' "$4" > "$b.idle"
    [ "${5:-0}" -gt 0 ] && printf '%s' "$5" > "$b.failed"
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
  printf 'Bash 4.0\n' > "$(ct_state_file "acct2").tools"
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

  fresh 'COLOR=none' 'ELAPSED=off' 'IDLE_AFTER=3600' 'DATE_ROLLOVER=off'
  printf '%s' "$(( $(date +%s) - 7200 ))" > "$(ct_state_dir)/gap.last"
  printf '{"session_id":"gap","index":0,"delta":"x"}' | bash "$SCRIPTS/message-display.sh" >/dev/null
  is_near "a marked break is added to the time away" 7200 "$(ct_read_counter "$(ct_state_dir)/gap.idle")" 3

  fresh 'TOOL_TIMING=on'
  printf '{"session_id":"f","tool_use_id":"t1","tool_name":"Bash"}' | bash "$SCRIPTS/pre-tool-use.sh"
  printf '{"session_id":"f","tool_use_id":"t1","tool_name":"Bash","hook_event_name":"PostToolUseFailure"}' \
    | bash "$SCRIPTS/post-tool-use.sh"
  is "a failed call is counted" "1" "$(ct_read_counter "$(ct_state_file f).failed")"
  is "a failed call is still timed" "1" "$(wc -l < "$(ct_tool_log f)" | tr -d ' ')"

  printf '{"session_id":"f","tool_use_id":"t2","tool_name":"Bash"}' | bash "$SCRIPTS/pre-tool-use.sh"
  printf '{"session_id":"f","tool_use_id":"t2","tool_name":"Bash","hook_event_name":"PostToolUse"}' \
    | bash "$SCRIPTS/post-tool-use.sh"
  is "a successful call is not counted as failed" "1" "$(ct_read_counter "$(ct_state_file f).failed")"
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

bash "$SCRIPTS/setup.sh" --history=off --history-limit=50 >/dev/null
ct_load_config
is "--history is accepted"       "off" "$CT_HISTORY"
is "--history-limit is accepted" "50"  "$CT_HISTORY_LIMIT"
refutes "a non on/off history is refused" bash "$SCRIPTS/setup.sh" --history=sometimes
refutes "a non-numeric limit is refused"  bash "$SCRIPTS/setup.sh" --history-limit=lots

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

refutes "no project config is reported as not found" ct_find_project_config "$PROJ/plain"
refutes "a missing directory is not searched"        ct_find_project_config "$PROJ/nowhere"
refutes "an empty directory argument finds nothing"  ct_find_project_config ""

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

# In a directory that has pinned nothing yet, --project on its own has no
# settings to write and should say so rather than create an empty file.
mkdir -p "$PROJ/empty"
refutes "--project with nothing to write is refused" \
  bash -c "cd '$PROJ/empty' && unset CLAUDE_TIMESTAMP_CONFIG && HOME='$PROJ/home' bash '$SCRIPTS/setup.sh' --project"
if [ -e "$PROJ/empty/.claude/claude-timestamp.conf" ]; then
  fail "a refused write leaves no file behind" "no file" "a file was created"
else
  pass "a refused write leaves no file behind"
fi

out="$( cd "$PROJ/writable" && unset CLAUDE_TIMESTAMP_CONFIG && HOME="$PROJ/home" \
        bash "$SCRIPTS/setup.sh" --doctor 2>&1 )"
contains "doctor names the project file" "project file" "$out"
out="$( cd "$PROJ/plain" && unset CLAUDE_TIMESTAMP_CONFIG && HOME="$PROJ/home" \
        bash "$SCRIPTS/setup.sh" --doctor 2>&1 )"
contains "doctor says when there is no project file" "none for this directory" "$out"

echo
echo "doctor"

fresh
out="$(bash "$SCRIPTS/setup.sh" --doctor)"
contains "doctor reports jq"           "jq" "$out"
contains "doctor reports the platform" "uname" "$out"
contains "doctor renders a preview"    "Preview" "$out"
contains "doctor reports no problems on a healthy setup" "No problems found" "$out"
asserts "doctor exits zero when healthy" bash "$SCRIPTS/setup.sh" --doctor

echo
echo "facts file"

fresh
rm -f "$CLAUDE_TIMESTAMP_FACTS"
printf '{"session_id":"facts"}' | bash "$SCRIPTS/session-start.sh" >/dev/null
asserts "facts: written at session start" test -r "$CLAUDE_TIMESTAMP_FACTS"
asserts "facts: valid json" jq -e . "$CLAUDE_TIMESTAMP_FACTS"
is "facts: reports jq present" "true" "$(jq -r '.jq' "$CLAUDE_TIMESTAMP_FACTS")"
is "facts: version matches version.txt" \
   "$(tr -d '[:space:]' < "$ROOT/version.txt")" \
   "$(jq -r '.version' "$CLAUDE_TIMESTAMP_FACTS")"
is "facts: state dir is writable here" "true" "$(jq -r '.state_dir_writable' "$CLAUDE_TIMESTAMP_FACTS")"
if ct_tz_supported; then
  is "facts: timezone database detected" "true" "$(jq -r '.tz_database' "$CLAUDE_TIMESTAMP_FACTS")"
else
  is "facts: timezone database absent" "false" "$(jq -r '.tz_database' "$CLAUDE_TIMESTAMP_FACTS")"
fi

# A stale file must be replaced rather than appended to or left alone.
printf 'not json at all' > "$CLAUDE_TIMESTAMP_FACTS"
printf '{"session_id":"facts"}' | bash "$SCRIPTS/session-start.sh" >/dev/null
asserts "facts: a stale file is replaced" jq -e . "$CLAUDE_TIMESTAMP_FACTS"

# Written by rename, so a concurrent reader cannot see a half-written file.
is "facts: no temp file left behind" "" "$(find "$WORK" -name 'facts.json.*' 2>/dev/null)"

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
   "unknown" "$(jq -r '.version' "$CLAUDE_TIMESTAMP_FACTS")"

echo
echo "----"
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
