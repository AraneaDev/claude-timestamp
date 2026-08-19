---
description: Configure claude-timestamp (timezone, clock format, colour, elapsed time)
argument-hint: what to change, e.g. "tokyo", "no colour", "12h no seconds", "off"
---

Configure the claude-timestamp plugin for this user.

Settings take effect on the **next message**. Every hook reads the config file
each time it runs, so nothing needs restarting. Say so when you report back,
because people reasonably assume otherwise.

The setup script has an interactive wizard, but it cannot be used from here:
the Bash tool has no interactive stdin. Drive the non-interactive form instead.

## What the user asked for

$ARGUMENTS

## How to do it

1. Read the current settings, so you can say what is changing rather than
   guessing:

   `bash "${CLAUDE_PLUGIN_ROOT}/hooks/scripts/setup.sh" --show`

2. Work out which flags the request maps to. If the request above is empty or
   vague, ask with AskUserQuestion. If it is specific, just do it, and do not
   interrogate the user about settings they did not mention.

   Some phrasings and what they mean:

   | They say | Flags |
   | --- | --- |
   | "tokyo", "use Japan time" | `--tz=Asia/Tokyo` |
   | "my own time", "local" | `--tz=local` |
   | "no colour", "plain" | `--color=none` |
   | "drop the seconds", "shorter" | `--display=short` |
   | "12 hour" | `--display=12h` |
   | "off", "stop timestamps" | `--elapsed=off --color=none` and explain that a marker still shows; full removal is `claude plugin disable` |
   | "don't tell Claude the time" | `--inject-context=false` |
   | "highlight slow turns after 30s" | `--slow-after=30` |
   | "time my tools" | `--tool-timing=on` |

3. Apply only what they asked for. Every flag is optional and anything left out
   keeps its current value:

   `bash "${CLAUDE_PLUGIN_ROOT}/hooks/scripts/setup.sh" --tz=Asia/Tokyo --display=short`

4. Report the preview line the script prints, and say the change is already
   live. If the script exits non-zero, relay its message: it refuses values it
   cannot honour, such as a pinned timezone on a machine with no timezone
   database.

## Settings

- Timezone: an IANA name such as `Europe/Amsterdam`, or `local`.
- Display format: `24h` (14:03:22), `short` (14:03), `12h` (2:03 PM),
  `iso` (2026-08-19T14:03:22), or any strftime string.
- Colour: `none`, `dim`, `gray`, `cyan`, `blue`, `green`, `yellow`, `magenta`,
  `red`. Also `--slow-color` for the duration of a slow turn.
- Elapsed: `on` or `off`, whether to show how long each turn took.
- Slow turns: `--slow-after=SECONDS` colours the duration past that point,
  `0` disables.
- Idle gaps: `--idle-after=SECONDS` marks a break between messages, `0`
  disables.
- Date rollover: `on` or `off`, showing the date after midnight.
- Summary: `on` or `off`, session totals on exit.
- Subagents: `on` or `off`, whether subagent messages are stamped.
- Tool timing: `on` or `off`. Off by default, and worth saying why if asked:
  it is the only setting that costs anything per tool call rather than per
  message.
- Inject context: `true` or `false`, whether Claude is told the local time each
  prompt was sent.
- History: `--history=on|off` records each finished session for `--stats`, and
  `--history-limit=N` decides how many are kept.

## Showing what the sessions add up to

If the user asks how long they have been spending, how much of it was waiting,
or anything else about their own usage, run:

`bash "${CLAUDE_PLUGIN_ROOT}/hooks/scripts/setup.sh" --stats`

It reports over the sessions recorded so far. The history holds timings only,
no message text and no paths, which is worth saying if they ask what is stored.

## When something is not working

Run the self-check and relay what it reports:

`bash "${CLAUDE_PLUGIN_ROOT}/hooks/scripts/setup.sh" --doctor`

It exits non-zero when something is actually wrong, and it names bad values in
the config file rather than leaving them to fail silently.

If the user would rather answer the questions themselves, the wizard needs a
real terminal:

`! bash "${CLAUDE_PLUGIN_ROOT}/hooks/scripts/setup.sh"`
