#!/usr/bin/env bash
# Deliberate no-op. Not bound by hooks.json -- kept only for compatibility.
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
# So the file stays, doing nothing, purely so a stale binding finds something
# harmless to run instead of nothing at all. Delete it once no supported
# version of this plugin still binds PreToolUse -- in practice, once every
# session that predates ad31d05 has cycled (restarted or ended), which for a
# CLI plugin means one release or two, not indefinitely.
#
# Invoked as `bash <this script>` (see the old hooks.json, not the current
# one), so it does not depend on the executable bit surviving clones, zips,
# or Windows checkouts.
exit 0
