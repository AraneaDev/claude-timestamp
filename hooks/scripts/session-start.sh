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

# jq is missing: the other hooks all fail safe and do nothing, so timestamps
# would silently never appear. Say so once, and build the JSON by hand since
# the tool we would use to build it is the thing that is missing.
if ! command -v jq >/dev/null 2>&1; then
  msg="claude-timestamp: 'jq' is not installed, so timestamps are off. Install it - macOS: brew install jq - Debian/Ubuntu: sudo apt-get install jq - Windows: winget install jqlang.jq - then restart Claude Code."
  printf '{"systemMessage": "%s"}\n' "$msg"
  exit 0
fi

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/config.sh"

cwd="$(cat | jq -r '.cwd // empty' 2>/dev/null || true)"

ct_prune_state

# A zone was pinned that this platform cannot resolve. The hooks fall back to
# local time rather than rendering UTC, but silently showing a different zone
# than the one configured is worth saying out loud, once.
ct_load_config "$cwd"

# Publish what cannot be worked out by reading files. This runs after
# ct_load_config because ct_tz_supported memoises into the same shell.
#
# jq is always true here: the hook returns early when jq is missing, so the
# file's absence carries that case. Recording it anyway means a reader gets one
# shape rather than having to infer a negative from a missing file.
ct_write_facts() {
  local file tmp root version writable=false
  file="$(ct_facts_path)"
  mkdir -p "$(dirname "$file")" 2>/dev/null || return 0

  # This script is hooks/scripts/session-start.sh, so the plugin root is two
  # levels up and version.txt sits directly in it.
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)" || root=""
  version="$(tr -d '[:space:]' 2>/dev/null < "$root/version.txt")" || version=""
  [ -n "$version" ] || version="unknown"

  if mkdir -p "$(ct_state_dir)" 2>/dev/null && : > "$(ct_state_dir)/.probe" 2>/dev/null; then
    writable=true
    rm -f "$(ct_state_dir)/.probe" 2>/dev/null
  fi

  # Temp file and rename, so a session starting while another reads this never
  # exposes a half-written file.
  tmp="$file.$$"
  if jq -n \
      --arg version "$version" \
      --argjson tz_database "$(ct_tz_supported && printf 'true' || printf 'false')" \
      --argjson state_dir_writable "$writable" \
      '{jq: true, tz_database: $tz_database, state_dir_writable: $state_dir_writable, version: $version}' \
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

# A typo in the config file would otherwise do nothing visible: the value is
# replaced by its default and the plugin carries on. Say it once, at the only
# moment that is not in the middle of a conversation.
if [ -n "${CT_CONFIG_PROBLEMS:-}" ]; then
  jq -n --arg problems "$CT_CONFIG_PROBLEMS" \
    '{systemMessage: ("claude-timestamp: some settings could not be used.\n" + $problems + "\nRun /timestamps to fix them.")}'
fi

if ct_tz_unhonoured; then
  jq -n --arg tz "$CT_TZ" '{systemMessage: ("claude-timestamp: this system has no timezone database, so " + $tz + " cannot be applied. Showing local time instead. Run /timestamps and choose \"local\" to silence this.")}'
fi

# First run: there is no README in this repo by design, so the config command
# has to introduce itself or nobody will ever know it exists.
if [ ! -r "$(ct_config_path)" ]; then
  jq -n '{systemMessage: "claude-timestamp is running with default settings. Run /timestamps to pick a timezone, clock format, and color."}'
fi

exit 0
