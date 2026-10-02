# What Claude is told

Part of the claude-timestamp documentation. Start at the [README](../README.md).

The marker is drawn on your screen and never reaches the model. A few short
notes do reach it, each as a system reminder, and each only when there is
something to say. `INJECT_CONTEXT=false` switches all of them off, and each
has a setting of its own.

| When | What Claude reads | Setting |
| --- | --- | --- |
| A session starts | `claude-timestamp reports turn length, slow tool calls, usually slow commands and resumed sessions in system reminders; the claude-timestamp:time-awareness skill explains them and can query session history.` | `INJECT_CONTEXT` |
| Every prompt | `Message sent at local time 10:37:21 CEST, after a 3h break` | `INJECT_CONTEXT`, `CONTEXT_FORMAT` |
| The first tool result after a turn passes 15 minutes, and every 15 after | `Turn running 15m02s (prompt sent 10:37:21); now 10:52:23 CEST.` | `HEARTBEAT_AFTER` |
| One tool call takes a minute or more | `That Bash call took 2m14s.` or, for a command with a few earlier runs here, `That Bash call took 6m10s (usually 4m02s).` | `SLOW_TOOL_AFTER` |
| A session starts in a project where some commands usually take a minute or more | `Usually slow in this project: bash tests/run.sh ~4m02s (12 runs).` | `COMMAND_MEMORY`, `SLOW_TOOL_AFTER` |
| A session starts an hour or more after the last one in this project, or a conversation is resumed an hour or more after its last activity | `Previous session in this project ended 14h ago (Thu 20:12:05).` or `Resuming this conversation; last activity 14h ago (Thu 20:12:05).` | `RESUME_NOTE` |
| A conversation is compacted | `Conversation compacted. Session started 09:12:05 (3h04m ago), 41 turns so far, 1h02m of it waiting. Longest turns: 10:37:21 (22m04s), 14:05:10 (15m30s).` | `RESUME_NOTE` |

The notes state facts and give no instructions. The advice lives in one place,
a skill the plugin ships, `time-awareness`, which Claude loads when a note
arrives or when you ask something like "how long has this session been
running?". It says what each note is a reason to do: check the work against
the request after a long stretch, run a slow command in the background next
time, re-check the branch and CI after a gap. It can also run
`setup.sh --session` and `--stats` to answer from measurement. It does not
appear in your `/` menu; `/timestamps` is still where you change settings.

<p align="center">
  <img src="../assets/skill.webp" alt="Claude loading the time-awareness skill and answering how long the session has run from the measured report" width="760">
</p>

<sub>A real session, recorded as it happened. Claude loads the skill, runs
`--session`, and answers with the measured numbers rather than an estimate.</sub>

A note can only reach Claude when a hook runs, so the turn-length note waits
for the next tool result. A single 31-minute command produces one note when
it finishes, not one at 15 minutes and another at 30.

Subagents hear about their own slow calls unless `SUBAGENTS` is `off`. The
turn-length note goes to the main conversation only, since the turn is yours
and theirs is a part of it.

The resumption note records nothing of its own. Claude Code already keeps a
transcript per session in a folder per project, and the note reads the time
from those. If that layout ever changes, the note goes quiet rather than
guessing.
