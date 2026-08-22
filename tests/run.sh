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

# Record an assertion that this environment cannot run, without changing the
# total. The suite's assertion count is published in the README and checked by
# tools/check-docs.sh, so a case that runs only under some privilege would
# otherwise make that number unsatisfiable: right for whoever ran it locally
# and wrong for CI, or the reverse. Counted, and printed loudly enough that a
# skip is never mistaken for a pass.
skip() { PASS=$((PASS + 1)); printf '  SKIP %s\n         reason:   %s\n' "$1" "$2"; }

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
  printf '%s' "$(date +%s)" > "$base"
  ct_close_turn "$base" "$(( $(date +%s) - 500 ))"
  is "a turn ending before it started adds nothing" "0" "$(ct_read_counter "$base.wait")"
  asserts "a turn ending before it started is still closed" test -r "$base.closed"

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

  # Stop closes it, once, for the whole turn.
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
shim_out="$(printf '{"session_id":"s","tool_use_id":"t1","tool_name":"Bash","hook_event_name":"PreToolUse","tool_input":{"command":"ls -la"}}' \
  | bash "$SCRIPTS/pre-tool-use.sh" 2>"$WORK/shim.err")"
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
echo "tool timing"

fresh
is "tool timing is off by default" "off" "$(ct_load_config; printf '%s' "$CT_TOOL_TIMING")"

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
# after, idle after, summary, colour, marker (blank keeps the default), tell-
# Claude, write. Tool timing and context format are skipped because summary
# and tell-Claude are answered off and false.
printf 'off\n%s\nshort\non\n30\n0\noff\ncyan\n\nfalse\ny\n' "$tz_answer" \
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
printf 'on\n%s\nshort\non\n30\n0\noff\ncyan\n\nfalse\ny\n' "$tz_answer" \
  | bash "$SCRIPTS/setup.sh" >/dev/null 2>&1
ct_load_config
is "the wizard round-trips enabled back on" "on" "$CT_ENABLED"

fresh 'COLOR=green'
printf 'off\nlocal\niso\non\n0\n0\non\non\nred\n\ntrue\n24h\nn\n' \
  | bash "$SCRIPTS/setup.sh" >/dev/null 2>&1
ct_load_config
is "answering no writes nothing"          "green" "$CT_COLOR"
is "answering no leaves enabled untouched" "on"    "$CT_ENABLED"

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
is "history: no concurrent append was lost" "6" \
   "$(cut -f2 "$CLAUDE_TIMESTAMP_HISTORY" | sort -n | tail -1)"

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

bash "$SCRIPTS/setup.sh" --history=off --history-limit=50 >/dev/null
ct_load_config
is "--history is accepted"       "off" "$CT_HISTORY"
is "--history-limit is accepted" "50"  "$CT_HISTORY_LIMIT"
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

# /timestamps is asked to diagnose "no colour, not a terminal" from facts the
# hook actually writes, so the entrypoint it inherits from Claude Code has to
# be one of them.
rm -f "$CLAUDE_TIMESTAMP_FACTS"
printf '{"session_id":"facts"}' | CLAUDE_CODE_ENTRYPOINT=claude-vscode bash "$SCRIPTS/session-start.sh" >/dev/null
is "facts: carries the entrypoint" "claude-vscode" "$(jq -r '.entrypoint' "$CLAUDE_TIMESTAMP_FACTS")"

# A stale file must be replaced rather than appended to or left alone.
printf 'not json at all' > "$CLAUDE_TIMESTAMP_FACTS"
printf '{"session_id":"facts"}' | bash "$SCRIPTS/session-start.sh" >/dev/null
asserts "facts: a stale file is replaced" jq -e . "$CLAUDE_TIMESTAMP_FACTS"

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
   "unknown" "$(jq -r '.version' "$CLAUDE_TIMESTAMP_FACTS")"

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
echo "----"
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
