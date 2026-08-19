#!/usr/bin/env bash
# SessionStart hook.
#
# Two jobs, both one-time-per-session: make sure the plugin can actually run,
# and make sure a new user can find the setup command. Everything here is
# advisory -- the session is never blocked, so we always exit 0.
#
# systemMessage is the documented way to put text in front of the USER. Plain
# stdout would only reach the model, which is the wrong audience for both of
# these messages.
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

ct_prune_state

# First run: there is no README in this repo by design, so the config command
# has to introduce itself or nobody will ever know it exists.
if [ ! -r "$(ct_config_path)" ]; then
  jq -n '{systemMessage: "claude-timestamp is running with default settings. Run /timestamps to pick a timezone, clock format, and color."}'
fi

exit 0
