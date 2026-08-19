---
description: Configure claude-timestamp (timezone, clock format, color, elapsed time)
---

Configure the claude-timestamp plugin for this user.

The setup script has an interactive wizard, but it cannot be used from here:
the Bash tool has no interactive stdin, so a wizard would hang. Drive the
non-interactive form instead.

1. Show the current configuration:

   `bash "${CLAUDE_PLUGIN_ROOT}/hooks/scripts/setup.sh" --show`

2. Ask the user what they want to change. Use AskUserQuestion, and ask only
   about what is relevant to their request. If they asked for something
   specific ("use Tokyo time", "drop the seconds"), just do it without
   interrogating them about the rest.

   - Timezone: an IANA name such as `Europe/Amsterdam`, or `local` for the
     machine's own time.
   - Display format: `24h` (14:03:22), `short` (14:03), `12h` (2:03 PM),
     `iso` (2026-08-19T14:03:22), or any strftime string.
   - Color: `none`, `dim`, `gray`, `cyan`, `blue`, `green`, `yellow`,
     `magenta`, `red`.
   - Elapsed: `on` or `off`, whether to show how long each turn took.
   - Inject context: `true` or `false`, whether Claude is told the local time
     each prompt was sent.

3. Apply only the settings they chose. Every flag is optional and anything you
   leave out keeps its current value:

   `bash "${CLAUDE_PLUGIN_ROOT}/hooks/scripts/setup.sh" --tz=Asia/Tokyo --display=short --color=dim`

4. Relay the preview line the script prints, and tell them the change takes
   effect in the next session.

If the user would rather use the interactive wizard, tell them to run this in
their terminal, where it has a real TTY:

`! bash "${CLAUDE_PLUGIN_ROOT}/hooks/scripts/setup.sh"`
