#!/usr/bin/env bash
# SessionStart hook.
#
# Three jobs, all one-time-per-session: make sure the plugin can actually run,
# make sure a new user can find the config command, and publish facts.json --
# what this machine can and cannot do, which /timestamps reads instead of
# probing for itself. Everything here is advisory -- the session is never
# blocked, so we always exit 0.
#
# systemMessage is the documented way to put text in front of the USER. Plain
# stdout would only reach the model, which is the wrong audience for all
# three of these messages.
#
# Invoked as `bash <this script>` (see hooks.json), so it does not depend on
# the executable bit surviving clones, zips, or Windows checkouts.
set -euo pipefail

# Which client this session is, as a key the facts file can be grouped under.
#
# Defined here rather than in lib/config.sh because the jq-missing branch below
# needs it and cannot source anything: resolving the lib directory costs a
# `dirname`, and that branch has to survive a PATH with nothing on it at all.
#
# Anything outside the character set Claude Code actually uses becomes
# "unknown". The jq path would escape a stray quote safely, but the branch that
# has no jq builds its JSON with printf and would emit a broken file, so both
# paths take the same narrow set and stay honest about the difference.
ct_client_key() {
  local key="${CLAUDE_CODE_ENTRYPOINT:-}"
  case "$key" in
    "" | *[!A-Za-z0-9_-]*) printf 'unknown' ;;
    *) printf '%s' "$key" ;;
  esac
}

# Seconds since the epoch, or 0 when `date` cannot be reached. A reader treats
# 0 as "no idea when", which is the truth in that case and reads as ancient
# rather than as fresh.
ct_epoch() {
  local now=""
  now="$(date +%s 2>/dev/null)" || now=""
  case "$now" in
    "" | *[!0-9]*) printf '0' ;;
    *) printf '%s' "$now" ;;
  esac
}

# jq is missing: the other hooks all fail safe and do nothing, so timestamps
# would silently never appear. Say so once, and build the JSON by hand since
# the tool we would use to build it is the thing that is missing.
#
# Saying it is not enough on its own. The message goes to the user, and a user
# who missed it (or a client that swallowed it) leaves nobody able to tell this
# apart from the plugin never having been installed here. So record it too,
# which is the one fact this branch can still write down.
if ! command -v jq >/dev/null 2>&1; then
  msg="claude-timestamp: 'jq' is not installed, so timestamps are off. Install it - macOS: brew install jq - Debian/Ubuntu: sudo apt-get install jq - Windows: winget install jqlang.jq - then restart Claude Code."
  printf '{"systemMessage": "%s"}\n' "$msg"

  # The path expression is the one in ct_facts_path, repeated rather than
  # sourced for the reason ct_client_key explains. If one moves, move both.
  #
  # This entry replaces the whole file rather than merging into it: merging
  # needs jq. Another client's entry is restored the next time that client
  # starts a session, and losing it meanwhile costs less than not recording
  # the only client we can currently see anything about.
  # Both checked before the redirect opens anything: without `mv` there is no
  # way to put the file in place, and without `rm` no way to clear the temp
  # file away again. Opening it first and finding out afterwards leaves litter
  # behind for a write that was never going to land.
  ct_facts="${CLAUDE_TIMESTAMP_FACTS:-${HOME:-}/.claude/claude-timestamp.facts.json}"
  ct_tmp="$ct_facts.$$"
  if command -v mv >/dev/null 2>&1 && command -v rm >/dev/null 2>&1 && printf '{"facts_version":2,"clients":{"%s":{"jq":false,"written_at":%s}}}\n' \
       "$(ct_client_key)" "$(ct_epoch)" > "$ct_tmp" 2>/dev/null; then
    mv "$ct_tmp" "$ct_facts" 2>/dev/null || rm -f "$ct_tmp" 2>/dev/null
  else
    rm -f "$ct_tmp" 2>/dev/null
  fi
  exit 0
fi

CT_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
source "$CT_LIB/config.sh"
source "$CT_LIB/state.sh"

cwd="$(cat | jq -r '.cwd // empty' 2>/dev/null || true)"

ct_prune_state

# A zone was pinned that this platform cannot resolve. The hooks fall back to
# local time rather than rendering UTC, but silently showing a different zone
# than the one configured is worth saying out loud, once.
ct_load_config "$cwd"

# Publish what cannot be worked out by reading files. This runs after
# ct_load_config because ct_tz_supported memoises into the same shell.
#
# jq is always true here: the branch above owns the false case and writes it
# down. The file's absence now means one thing only -- no session of this
# plugin has ever started on this machine -- which is the difference between
# "not installed here" and "installed but hobbled", and the two want opposite
# fixes.
#
# Entries are keyed by client because one home directory can serve several. A
# terminal and the desktop app's Code tab share ~/.claude on macOS, and a flat
# file meant the last session to start described every client, so reading it
# after a failing desktop session could hand you the terminal's healthy answer.
ct_write_facts() {
  local file tmp root version writable=false probe
  file="$(ct_facts_path)"
  mkdir -p "$(dirname "$file")" 2>/dev/null || return 0

  # This script is hooks/scripts/session-start.sh, so the plugin root is two
  # levels up and version.txt sits directly in it.
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)" || root=""
  version="$(tr -d '[:space:]' 2>/dev/null < "$root/version.txt")" || version=""
  [ -n "$version" ] || version="unknown"

  # A fixed filename in a shared directory can be pre-planted as a symlink, and
  # `: >` follows it. The pid makes the name unguessable to anyone who is not
  # already able to watch this process.
  probe="$(ct_state_dir)/.probe.$$"
  if ct_state_ready && : > "$probe" 2>/dev/null; then
    writable=true
    rm -f "$probe" 2>/dev/null
  fi

  # Read what other clients left before overwriting them. Anything that is not
  # a v2 file -- absent, unreadable, not JSON, or the old flat shape from
  # before this was keyed -- starts again from empty, which is also how a
  # corrupted file gets replaced rather than half-preserved.
  local prior='{}'
  if [ -r "$file" ]; then
    prior="$(jq -c 'if type == "object" and (.clients | type) == "object"
                    then . else {} end' "$file" 2>/dev/null)" || prior='{}'
    [ -n "$prior" ] || prior='{}'
  fi

  # Temp file and rename, so a session starting while another reads this never
  # exposes a half-written file. Two sessions starting at the same instant can
  # still cost one entry, since each read its own copy before writing; the
  # loser is restored by that client's next session start.
  tmp="$file.$$"
  if jq -n \
      --argjson prior "$prior" \
      --arg key "$(ct_client_key)" \
      --arg version "$version" \
      --argjson tz_database "$(ct_tz_supported && printf 'true' || printf 'false')" \
      --argjson state_dir_writable "$writable" \
      --argjson written_at "$(ct_epoch)" \
      '$prior + {facts_version: 2}
       | .clients = ((.clients // {}) + {
           ($key): {
             jq: true,
             tz_database: $tz_database,
             state_dir_writable: $state_dir_writable,
             version: $version,
             written_at: $written_at
           }
         })' \
      > "$tmp" 2>/dev/null; then
    mv "$tmp" "$file" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  else
    rm -f "$tmp" 2>/dev/null
  fi
  return 0
}

ct_write_facts

# Off silences the advisories, but only after the facts have been published:
# without them, /timestamps would have no way to switch the plugin back on.
[ "$CT_ENABLED" = "on" ] || exit 0

# Everything below is a thing worth saying once, at the only moment that is not
# in the middle of a conversation. They are collected rather than printed as
# they are found, because a hook returns one object: three jq calls each
# printing a complete one produced a stream, and a consumer parsing a single
# object rejects the lot -- losing every message exactly when there was most to
# say.
#
# The order below is deliberate and not alphabetical: what is broken, then what
# cannot be honoured, then what merely exists. A user with a typo in their
# config needs to see that before an introduction to a command they have
# already found, and a timezone that cannot be applied is a degraded setting
# rather than a rejected one. Reordering these changes what a first-time user
# reads first, so it is a UX decision rather than a formatting one.
notes=""
_ct_add_note() { notes="${notes}${notes:+$'\n\n'}$1"; }

# A typo in the config file would otherwise do nothing visible: the value is
# replaced by its default and the plugin carries on.
if [ -n "${CT_CONFIG_PROBLEMS:-}" ]; then
  _ct_add_note "claude-timestamp: some settings could not be used.
${CT_CONFIG_PROBLEMS}
Run /timestamps to fix them."
fi

if ct_tz_unhonoured; then
  _ct_add_note "claude-timestamp: this system has no timezone database, so ${CT_TZ} cannot be applied. Showing local time instead. Run /timestamps and choose \"local\" to silence this."
fi

# First run: there is no README in this repo by design, so the config command
# has to introduce itself or nobody will ever know it exists.
if [ ! -r "$(ct_config_path)" ]; then
  _ct_add_note "claude-timestamp is running with default settings. Run /timestamps to pick a timezone, clock format, and color."
fi

# An `if` rather than `[ ... ] && jq ...`: under set -e an AND-list whose test
# fails returns non-zero, and the only thing making that harmless here is the
# `exit 0` on the next line. That is safety at a distance -- delete or move the
# exit and a session with nothing to say starts reporting failure. The branch
# carries its own exit status.
if [ -n "$notes" ]; then
  jq -n --arg msg "$notes" '{systemMessage: $msg}'
fi

exit 0
