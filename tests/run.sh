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
refutes() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then fail "$label" "non-zero exit" "exit 0"; else pass "$label"; fi
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

CT_TZ="UTC"
case "$(ct_now 12h)" in 0*) fail "12h preset trims the leading zero" "no leading zero" "$(ct_now 12h)" ;; *) pass "12h preset trims the leading zero" ;; esac

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

  # A turn that started 134 seconds ago should render as +2m14s.
  printf '%s' "$(( $(date +%s) - 134 ))" > "$(ct_state_dir)/test-session"
  out="$(printf '{"session_id":"test-session","index":0,"delta":"x"}' | bash "$SCRIPTS/message-display.sh" | jq -r '.hookSpecificOutput.displayContent')"
  contains "message-display renders elapsed time" "+2m14s" "$out"

  printf 'ELAPSED=off\n' > "$CLAUDE_TIMESTAMP_CONFIG"
  out="$(printf '{"session_id":"test-session","index":0,"delta":"x"}' | bash "$SCRIPTS/message-display.sh" | jq -r '.hookSpecificOutput.displayContent')"
  case "$out" in *"+"*) fail "ELAPSED=off hides the duration" "no + marker" "$out" ;; *) pass "ELAPSED=off hides the duration" ;; esac

  printf 'INJECT_CONTEXT=false\n' > "$CLAUDE_TIMESTAMP_CONFIG"
  out="$(printf '{"session_id":"test-session","prompt":"hi"}' | bash "$SCRIPTS/user-prompt-submit.sh")"
  is "INJECT_CONTEXT=false injects nothing" "" "$out"

  # ELAPSED=off so this asserts only on the time rendering itself.
  printf 'COLOR=none\nDISPLAY_FORMAT=short\nTZ=UTC\nELAPSED=off\n' > "$CLAUDE_TIMESTAMP_CONFIG"
  out="$(printf '{"session_id":"test-session","index":0,"delta":"x"}' | bash "$SCRIPTS/message-display.sh" | jq -r '.hookSpecificOutput.displayContent')"
  expected="[$(TZ=UTC date '+%H:%M')] x"
  is "config drives the rendered marker end to end" "$expected" "$out"

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

echo
echo "----"
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
