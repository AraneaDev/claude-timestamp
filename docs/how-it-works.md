# How it works

Part of the Timestamps documentation. Start at the [README](../README.md).

Six scripts across eight events, and one skill. Most of it is harness-only and
costs no model context. The exceptions are the short notes listed under
[What Claude is told](agent-notes.md), which three of the hooks add and
`INJECT_CONTEXT=false` switches off.

| Hook | Job |
| --- | --- |
| `SessionStart` | Check `jq`, prune old state, point a new user at `/timestamps:configure`; tell Claude how long ago this project or conversation was last active, and that the skill exists |
| `UserPromptSubmit` | Open the turn, close one an interrupt left behind, tell Claude the local time |
| `MessageDisplay` | Draw the marker on the first batch of each message |
| `Stop` / `StopFailure` | Close the turn and record what it cost |
| `SessionEnd` | Report the summary, record the session, clear its state |
| `PostToolUse` / `PostToolUseFailure` | Tell Claude when a turn runs long or a call was slow; with `TOOL_TIMING=on`, record what each call cost |

The skill, `skills/time-awareness/SKILL.md`, is plain instructions that Claude
loads when a note arrives or a time question comes up. It adds nothing to a
session until then.

A turn is opened by the prompt that started it and closed by the event that
ended it, so what a turn cost is measured once rather than accumulated as its
messages arrive. A turn that ends in neither `Stop` nor `StopFailure`, which is
what an interrupt looks like from a hook, is closed by the next prompt using
the last message it drew.

`MessageDisplay` fires repeatedly as a message streams. Only the first batch is
stamped, and the rest return nothing at all, which Claude Code treats as "show
the original text". Returning the text unchanged would have meant a wasted
round trip on every batch of every message. The hook decides in the shell,
before `jq` or anything else forks, whether a batch needs stamping at all, so
a later batch costs nothing more than that one check.

Timing state lives in `$TMPDIR/claude-timestamp-<your uid>`, one small file per
session, cleared when the session ends and pruned after seven days. The
directory is created private to you, and one belonging to somebody else is
declined rather than written into.

## The live layer

Claude Code builds that load hooks modules also run `hooks/mod/`, a TypeScript
module named in `hooks.json` beside the scripts. It measures and records
nothing. It reads what the scripts staged for the session (whether the plugin
and `LIVE` are on, the session's start, the slow-tool threshold, the project)
and the command memory, and draws from them while a turn is still running: a
clock among the dim labels in the footer, and, once a tool passes its usual
time, that time in the line under the call (a Bash call in the terminal) or in
a line above the prompt (any other tool, and the desktop). A call that waited
on a permission dialog, or that asks you a question, is left out: its time is
partly yours, and nothing says when you answered. While the line above the
prompt shows, it takes the place of anything else a plugin draws there. If the
module fails, or the build has no modules, the plugin behaves exactly as
described above. Codex never loads it.
