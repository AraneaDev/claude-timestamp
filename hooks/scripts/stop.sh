#!/usr/bin/env bash
# Stop and StopFailure hook -- closes the turn a prompt opened.
#
# This is the event that knows a turn ended. Before it was bound, the elapsed
# marker's own measurement was the closest thing available, so message-display
# accumulated waiting on every message and carried a correction to stop itself
# double-counting a figure that grows across a turn. That correction is gone:
# a turn is measured once, here, from end to end.
#
# The same script serves StopFailure, because a turn that ended in an error is
# still a turn the user waited through. A turn that ends in neither -- an
# interrupt -- is reconciled by the next prompt instead.
#
# Emits nothing: this hook only writes its own state and exits 0.
#
# Invoked as `bash <this script>` (see hooks.json), so it does not depend on
# the executable bit surviving clones, zips, or Windows checkouts.
set -euo pipefail

# No jq: leave the turn open rather than guessing at a session id. The next
# prompt reconciles it from the last message drawn.
command -v jq >/dev/null 2>&1 || exit 0

CT_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
source "$CT_LIB/config.sh"
source "$CT_LIB/state.sh"

input="$(cat)"
# The payload carries the directory the conversation is about, which is what
# decides whether a project has its own settings.
IFS=$'\x1f' read -r session_id cwd agent_id <<< "$(printf '%s' "$input" \
  | jq -r '[(.session_id // ""), (.cwd // ""), (.agent_id // "")] | join("\u001f")')"

# Defensive, not a fix for anything reproduced: Stop and SubagentStop come
# from one dispatcher that hooks.json binds separately by event name, so a
# subagent finishing should never reach a script bound only to Stop. Checking
# anyway makes that assumption explicit rather than implicit -- a subagent
# completing is not the end of the user's turn, and must not close one.
[ -n "$agent_id" ] && exit 0

ct_load_config "$cwd"

# The master switch. Everything below writes state, and off means none of it.
[ "$CT_ENABLED" = "on" ] || exit 0
# Waiting is only ever read by the summary and the history it feeds, so with
# the summary off there is nothing to accumulate it for.
[ "$CT_SUMMARY" = "on" ] || exit 0

state_file="$(ct_state_file "$session_id")" || exit 0
ct_close_turn "$state_file" "$(date +%s)"

exit 0
