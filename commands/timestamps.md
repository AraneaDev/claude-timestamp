---
description: Configure claude-timestamp (timezone, clock format, colour, elapsed time)
argument-hint: what to change, e.g. "tokyo", "no colour", "12h no seconds", "off"
---

Configure the claude-timestamp plugin for this user.

Settings take effect on the **next message**. Every hook reads the config file
each time it runs, so nothing needs restarting. Say so when you report back,
because people reasonably assume otherwise.

Do all of this by reading and editing files, with Read, Edit and Write. Do not
use the Bash tool for any of it: not to read the settings, not to work out the
time, not to check whether a program is installed, not to apply a change. There
is a terminal wizard, and the last section says how to reach it, but driving it
from here is slower, noisier, and needs a Bash permission the user does not
otherwise have to grant.

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

   If it is missing, either no session has started since this version was
   installed, or `jq` is not installed. The files cannot tell you which, and
   the last section says what to do about that. Do not guess at the facts the
   file would have held.

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

Applying a preset from `schema.json` is the same job in bulk: name the keys it
writes before writing them, and write exactly the keys its `set` object lists
and no others. Presets change several settings at once and the user should not
have to discover which. `quieter`, `default` and `detailed` all write the same
five keys, so moving between them never leaves a setting behind from the one
before. None of them touches `COLOR`: all three would write it to the same
value, so it carries no residue either way, and leaving it out means a
deliberate `COLOR=none` survives switching presets. `off` writes `ENABLED`
alone, deliberately, so switching back on restores everything else as it was.

`default` is the default marker, not a factory reset. It leaves the other
eleven keys as they are, `TZ` and `INJECT_CONTEXT` among them. That is usually
what someone asking for the defaults back wants, a pinned timezone especially, but
say which settings it left alone when you report, or the name promises more
than it delivered.

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

When a project pins the very key the request is about, editing the user's file
would achieve nothing: the project layer is read second and wins. Do not write
it anyway and report success. Say which file pins that key, and ask whether to
change that file instead, because a project config is usually committed and
shared with everyone working in the repository.

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
| "make the time gray" | `TIME_COLOR=gray` |
| "colour the duration cyan" | `ELAPSED_COLOR=cyan` |
| "no brackets" | `MARKER=%time{ %elapsed}` |
| "just the clock" | `MARKER=%time` |

Colour is named in words, never drawn. A preview box is markdown and cannot show
ANSI, so "time gray, duration cyan" is the honest way to report a part colour,
the same way this command already handles `COLOR`. An empty part colour means it
follows `COLOR`, which is what "inherit" means in the settings table.

`SLOW_COLOR` still wins over `ELAPSED_COLOR` once a turn passes `SLOW_AFTER`.
Say so if a user sets `ELAPSED_COLOR` and then asks why a slow turn is a
different colour.

A request that is really the name of a preset is specific too: "quieter",
"more detail", "off". Apply that preset rather than asking, and name the keys
it writes. "Back to the defaults" is the `default` preset, which resets the
marker and nothing else, so name what it did not reset when you report.

Report what changed, from what to what, and that it is already live.

## When the request is empty or vague

Show them where they are, then offer the presets from `schema.json`.

First render the current settings' clock, in the format and colour they
actually produce, so they are looking at the thing rather than at a table.
Show the clock only, never a duration: elapsed time and tool attribution are
measured by the hook after a reply finishes, and you are answering
mid-conversation, before this reply has one. A plausible-looking `+2m14s` here
would be a guess wearing the shape of a measurement, not an illustrative
example, so leave it out rather than label it.
State the rest of the current settings in words, including whether elapsed and
tool timing are on:

```
Currently:  [13:22:13]
            Europe/Amsterdam, dim, elapsed on, tool timing off, slow at 60s
```

The clock in that line is the time the plugin told you at the start of this
message. If it did not, because `INJECT_CONTEXT` is false, use a plainly
made-up time and say it is an example. Either way there is nothing to look up.

Add a line naming the project config when one is in play.

Then ask what they want to change, with AskUserQuestion. One question,
single-select, three options:

- **How it looks**, the marker's layout, from the `markers` block. Drill into
  the picker below.
- **How much it says**, the presets from the `presets` block, which is the
  question this command used to ask directly.
- **Timezone and clock**, meaning `TZ`, `DISPLAY_FORMAT` and `CONTEXT_FORMAT`.

The router exists because AskUserQuestion accepts at most four options, and a
marker look and a behaviour preset are different axes: a preset is a whole
configuration, a look is one template. Offering both in one question would ask
the user to choose between things that are not alternatives.

"Other" is free, so a request to change one particular setting still arrives
there and should be taken straight to that setting without going through a
picker.

### The looks picker

Read the `markers` object from `schema.json`. Ask one single-select question
with up to four of them as options. Each option's `description` is that entry's
`describes`, and each option's `preview` is its `renders`, used verbatim.

Do not compose a preview yourself. The `renders` strings are asserted against
the real renderer by the test suite, which is the only reason they can be
trusted; a preview you assemble by reasoning about a template is a guess
wearing the shape of a measurement.

Applying a look writes `MARKER` and nothing else.

### A template the user writes

"Other" on the looks picker is where a hand-written template arrives, either as
a string or described in words. Before writing it, check it against the grammar
in `schema.json`:

- The parts are `%time`, `%elapsed`, `%tool` and `%date`. A `%` followed by
  letters must spell one of those four exactly. `%elapsd` is a typo and
  `%timex` is not `%time` followed by an `x`; refuse both and name the four
  valid parts.
- A `%` followed by anything else is literal, so `100%` is fine.
- A `{...}` group disappears when every part inside it is empty. Braces must
  balance.
- Outside a group, an empty part eats one run of spaces, so `[%time %elapsed]`
  reads correctly when the duration is absent. A part decorated with anything
  other than spaces needs a group: write `%time{ (%elapsed)}`, not
  `%time (%elapsed)`, or the parentheses will be left behind on their own.

Refuse to write a template that fails any of those, and say which rule it broke.
A bad value is not silently ignored: the plugin replaces it with the default and
complains at the next session start, so writing it would trade one confusion for
a worse one.

Do not show a rendered preview of a template you were given. You cannot run the
renderer, and a preview you reason out is exactly the guess the stored previews
exist to avoid. Say instead that the next message will show it, which is true:
settings take effect on the next message, so the real marker appears in their
own terminal, in real colour, one turn from now.

### The presets picker

Unchanged from before: the four presets as four options, each preview rendered
as that preset would really produce it, `off` among them so switching the plugin
off stays reachable.

Ask with AskUserQuestion. One question, single-select, and the four presets as
its four options: the tool accepts at most four, and it always offers an
"Other" of its own for free text.

Each option carries two fields, and both matter. The `description` is the
sentence about what that preset changes, which is its `describes` in
`schema.json`. The `preview` is the marker itself, rendered as that preset
would really produce it. The previews are the point of this question: they turn
four names into four things the user can look at and compare, which is what
picking a marker actually needs. They are supported on single-select questions
only, so do not set `multiSelect` on this one.

The result reads roughly like this:

```
? What would you like?
  > Quieter      [13:22]
    Default      [13:22:13 +2m14s]
    Detailed     [13:22:13 +2m14s · Bash 1m58s]
    Off          no marker at all
```

"Other" is where a request to change one particular thing arrives, so take
whatever they type there and drill into that setting. Offer walking every
setting in the text above the question rather than spending an option on it.
Use this exact phrasing, with no number in it: "say so and I'll go through
them one at a time, in schema order." Counting the keys yourself and naming a
total is not the job; the schema's key set changes, and a stale count would
be a bug you shipped by hand. If they ask for that, go through them in the
order `schema.json` lists them.

Every preview must render what that preset really produces, under that
preset's own settings rather than the current ones:

- The marker is the clock, in that preset's `DISPLAY_FORMAT`, inside square
  brackets.
- `ELAPSED=on` adds how long the turn took: `[13:22:13 +2m14s]`.
- A turn at or past `SLOW_AFTER` seconds has that duration drawn in
  `SLOW_COLOR`, and with `TOOL_TIMING=on` the tool that took at least half the
  turn is named after it: `[13:22:13 +2m14s · Bash 1m58s]`.
- `ENABLED=off` produces no marker at all, so its preview says exactly that,
  in words, rather than showing an empty box.
- Never put a date in a preview unless `DISPLAY_FORMAT` itself asks for one.
  `DATE_ROLLOVER` shows a date only on the first message after the session
  crosses midnight, so a dated preview would be promising something the user
  will not see.

Colour cannot be drawn in a preview box, so name it in words: underneath the
marker in the block above, and in the option's description here. None of the
three presets sets `COLOR`, so the colour you name there is the current one,
unchanged by whichever preset the user picks, not something the preset itself
produces. The terminal wizard makes a point of previews being drawn by the
same code as the real marker, and this question inherits that promise, so a
preview that is a guess is worse than no picker at all.

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

- A facts file that exists proves `jq` works: the hook that writes it exits
  before writing anything when `jq` is missing.
- No facts file: either no session has started since this version was
  installed, or `jq` is missing. Nothing on disk separates those two, so do not
  go looking for a way to tell. Say it is one of the two and let the user
  settle it: when `jq` is missing the plugin says so out loud at the start of
  every session, so they will know whether they have seen that.
- `state_dir_writable` is false: the plugin cannot record turn starts, so
  elapsed times and the summary will be missing.
- `tz_database` is false and `TZ` is pinned to an IANA name: the plugin is
  showing local time instead, and says so at session start.
- A value `schema.json` rejects: the plugin is using the default instead.
- `ENABLED=off`: everything is switched off, which is easy to forget having
  done.
- The marker has no colour: check the facts file's `entrypoint`. `cli` is the
  only value that gets colour, because colour is only emitted for a real
  terminal session; anything else, such as `claude-vscode`, is a client that
  does not interpret ANSI, so the plugin sends plain text there on purpose. An
  empty `entrypoint` almost always means an older Claude Code that predates
  this variable, which still gets colour, so look at the terminal itself if
  colour is missing there. `FORCE_COLOR=1` turns colour on regardless of
  `entrypoint`; `NO_COLOR` still wins over everything, including
  `FORCE_COLOR`.

If none of those explain it, stop there rather than inventing a next step. Say
what you checked and what each answer was, so the user can see the ground you
covered. A person at a terminal can look at things no file records, and the
line below is how they get there.

If the user would rather answer the questions themselves in a terminal, the
wizard needs a real TTY:

`! bash "${CLAUDE_PLUGIN_ROOT}/hooks/scripts/setup.sh"`
