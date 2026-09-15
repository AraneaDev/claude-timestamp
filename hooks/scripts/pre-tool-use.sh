#!/usr/bin/env bash
# Deliberate no-op for Claude Code. Codex also uses this path, with the
# CT_CODEX_HOOK marker set by its separate hook map, to measure a tool call
# when Codex does not provide Claude Code's duration_ms field.
#
# ad31d05 removed the PreToolUse binding and this file, because Claude Code
# now hands post-tool-use.sh the duration it used to measure itself. That is
# correct for any session that starts after the update: hooks.json is read
# fresh, and a fresh read has no PreToolUse entry at all.
#
# It is wrong for a session already running when the update lands, because
# hooks are bound once at session start. That session goes on holding the old
# PreToolUse binding for the rest of its life and keeps trying to exec this
# path, failing with "No such file or directory" on every single tool call
# until the user restarts. Non-blocking, so nothing actually breaks, but noisy
# in exactly the way this plugin avoids everywhere else.
#
# The unmarked path stays a no-op, so an old Claude Code session that still has
# the removed PreToolUse binding remains harmless. Codex's marked path is
# additive and only writes timing state for the current Codex session.
#
# Invoked as `bash <this script>` (see the old hooks.json, not the current
# one), so it does not depend on the executable bit surviving clones, zips,
# or Windows checkouts.
set -euo pipefail

[ "${CT_CODEX_HOOK:-}" = "1" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

CT_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
source "$CT_LIB/config.sh"
source "$CT_LIB/state.sh"

# With all tool-facing features off, preserve the free path and do not create
# per-call files merely because Codex supports this event.
ct_timing_wanted || exit 0

IFS=$'\x1f' read -r session_id tool_use_id cwd <<< "$(jq -r \
  '[(.session_id // ""), (.tool_use_id // ""), (.cwd // "")] | join("\u001f")')"
[ -n "$session_id" ] && [ -n "$tool_use_id" ] || exit 0

ct_read_flag_var "$session_id" "enabled"
enabled="$_CT_FLAG"
if [ -z "$enabled" ]; then
  ct_load_config "$cwd"
  enabled="$CT_ENABLED"
fi
[ "$enabled" = "on" ] || exit 0

if ct_state_ready && start_file="$(ct_tool_start_file "$session_id" "$tool_use_id")"; then
  printf '%s' "$(date +%s)" > "$start_file"
fi

exit 0
