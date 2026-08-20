---
description: Configure claude-timestamp (timezone, clock format, colour, elapsed time)
argument-hint: what to change, e.g. "tokyo", "no colour", "12h no seconds", "off"
---

Configure the claude-timestamp plugin for this user.

Settings take effect on the **next message**. Every hook reads the config file
each time it runs, so nothing needs restarting. Say so when you report back,
because people reasonably assume otherwise.

Do all of this by reading and editing files, with Read, Edit and Write. Nothing
here needs a shell: not reading the settings, not working out the time, not
applying a change. There is a terminal wizard, and the last section says how to
reach it, but driving it from here is slower, noisier, and needs a Bash
permission the user does not otherwise have to grant.

## What the user asked for

$ARGUMENTS

## What to read first

1. `${CLAUDE_PLUGIN_ROOT}/schema.json` is the contract. Its `keys` object holds
   every setting, its default, its acceptable values and what it does. Its
   `presets` object holds a handful of whole configurations, each one naming
   the exact set of keys it writes. Treat it as the only source of truth about
   what a key may hold.

2. `~/.claude/claude-timestamp.facts.json` holds what you cannot work out by
   reading files: whether this machine has a timezone database, whether the
   state directory is writable, and which plugin version is installed. It is
   rewritten at every session start, so it describes this machine as it is now.

   If it is missing, the plugin has not started a session since this version
   was installed, or `jq` is not installed. Say which you suspect rather than
   guessing at the facts it would have held.

3. `~/.claude/claude-timestamp.conf` is the user's settings. A key that is
   absent means the default from `schema.json`, so an absent key is not a
   problem to fix.

4. A project may override settings in `.claude/claude-timestamp.conf`. Walk up
   from the current directory looking for one, stopping at the home directory,
   because the file directly under home is the user's own config rather than a
   project's. Walking up means reading `<directory>/.claude/claude-timestamp.conf`
   at each level and taking the first one that exists; a level with no such
   file is the normal case rather than an error. If one is in play, say so
   before changing anything: a user puzzled that their timezone will not stick
   is usually looking at a project that pinned it.

Expand `~` to the user's home directory yourself. Read wants an absolute path.

## How to change something

Edit one key at a time. Never rewrite the whole file. Unknown keys are ignored
by the parser, so a key written by a newer version of the plugin must survive
you editing the line next to it.

- The key exists: edit that line.
- The key is absent: append it.
- The file does not exist: create it with a `# claude-timestamp configuration`
  header comment and only the keys you are setting.

Refuse to write a value `schema.json` does not accept, and say what the
acceptable ones are. A bad value is not silently ignored: the plugin replaces
it with the default and complains at the next session start.

Refuse to pin a timezone when `tz_database` is false in the facts file. That
machine resolves every IANA name to UTC without saying so, which would show a
confidently wrong time. `UTC` and `GMT` are fine there, since they need no
database.

To change a project's settings rather than the user's, edit the project file
instead, and write only the keys being pinned. A project config exists to pin
one or two things, so writing the full set would shadow the user's own
configuration and freeze it at today's values.

## When the request is specific

Do it, and do not interrogate the user about settings they did not mention.
Some phrasings and what they mean:

| They say | What to set |
| --- | --- |
| "tokyo", "use Japan time" | `TZ=Asia/Tokyo` |
| "my own time", "local" | `TZ=` (empty) |
| "no colour", "plain" | `COLOR=none` |
| "drop the seconds", "shorter" | `DISPLAY_FORMAT=short` |
| "12 hour" | `DISPLAY_FORMAT=12h` |
| "off", "stop timestamps" | `ENABLED=off` |
| "don't tell Claude the time" | `INJECT_CONTEXT=false` |
| "highlight slow turns after 30s" | `SLOW_AFTER=30` |
| "time my tools" | `TOOL_TIMING=on` |
| "why was that slow" | `TOOL_TIMING=on`, and explain it names the worst tool in the marker from now on |

A request that is really the name of a preset is specific too: "quieter",
"more detail", "back to the defaults", "off". Apply that preset rather than
asking, and name the keys it writes.

Report what changed, from what to what, and that it is already live.

## When the request is empty or vague

Show them where they are, then offer the presets from `schema.json`.

First render the current settings as the marker they actually produce, so they
are looking at the thing rather than at a table:

```
Currently:  [13:22:13 +2m14s]
            Europe/Amsterdam, dim, slow at 60s
```

The clock in that line is the time the plugin told you at the start of this
message. If it did not, because `INJECT_CONTEXT` is false, use a plainly
made-up time and say it is an example. Either way there is nothing to look up.

Add a line naming the project config when one is in play.

Then ask with AskUserQuestion, one question, with each preset as an option and
its rendered marker as the option's description. Add two more options: "change
one thing", which asks which setting and then drills into it, and "walk every
setting", which goes through them in the order `schema.json` lists them.

Every preview must render what that preset really produces:

- The marker is the clock, in `DISPLAY_FORMAT`, inside square brackets.
- `ELAPSED=on` adds how long the turn took: `[13:22:13 +2m14s]`.
- A turn at or past `SLOW_AFTER` seconds has that duration drawn in
  `SLOW_COLOR`, and with `TOOL_TIMING=on` the tool that took at least half the
  turn is named after it: `[13:22:13 +2m14s · Bash 1m58s]`.
- `ENABLED=off` produces no marker at all, so its preview is that absence.
- The date never appears unless the format asks for it, because `DATE_ROLLOVER`
  only shows a date after the session crosses midnight.

Colour cannot be shown in chat, so name it in words on the line underneath, as
the example above does. The terminal wizard makes a point of previews being
drawn by the same code as the real marker, and this inherits that promise.

When a preset is chosen, name the keys it writes before writing them, and write
exactly the keys its `set` object lists and no others. Presets change several
settings at once and the user should not have to discover which.

## Showing what the sessions add up to

If the user asks how long they have been spending, or how much of it was
waiting, read `~/.claude/claude-timestamp-history.tsv`. One finished session per
line, tab separated: when, seconds, turns, waited, idle, failed tools. It is
capped at `HISTORY_LIMIT` lines, 200 by default, so it fits in one read and the
totals are yours to add up.

It holds timings only, no message text and no paths, which is worth saying if
they ask what is stored.

## When something is not working

Read the facts file and the config files, and check them against
`schema.json`:

- No facts file: no session has started since the plugin was installed, or
  `jq` is missing. Timestamps need `jq`.
- `state_dir_writable` is false: the plugin cannot record turn starts, so
  elapsed times and the summary will be missing.
- `tz_database` is false and `TZ` is pinned to an IANA name: the plugin is
  showing local time instead, and says so at session start.
- A value `schema.json` rejects: the plugin is using the default instead.
- `ENABLED=off`: everything is switched off, which is easy to forget having
  done.

If the user would rather answer the questions themselves in a terminal, the
wizard needs a real TTY:

`! bash "${CLAUDE_PLUGIN_ROOT}/hooks/scripts/setup.sh"`
