---
name: timestamps
description: Configure claude-timestamp when the user asks to change timestamps, timezone, clock format, marker appearance, elapsed time, tool timing, summaries, history, or model-facing time notes.
---

# Configure claude-timestamp

Use the repository's CLI so configuration is parsed and validated by the same
code used by the hooks. Run commands from the Git root, or resolve the root
with `git rev-parse --show-toplevel`.

Read `schema.json` first when the user asks for a setting you do not recognize.
It is the source of truth for keys, accepted values, aliases, presets, and
marker grammar. Do not silently invent or accept a value the schema rejects.

Show current settings with:

```bash
bash "$(git rev-parse --show-toplevel)/hooks/scripts/setup.sh" --show
```

Use the matching CLI flag for a requested change, for example:

```bash
bash "$(git rev-parse --show-toplevel)/hooks/scripts/setup.sh" --tz=Europe/Amsterdam
bash "$(git rev-parse --show-toplevel)/hooks/scripts/setup.sh" --format=short
bash "$(git rev-parse --show-toplevel)/hooks/scripts/setup.sh" --color=none
bash "$(git rev-parse --show-toplevel)/hooks/scripts/setup.sh" --tool-timing=on
```

Use `--help` and the flag table in `hooks/scripts/setup.sh` for the complete
mapping. For several changes, pass several flags in one invocation. Report
what changed and say that it takes effect on the next message.

For measured reports, use `--session` or `--stats`; do not estimate duration
from the conversation. History stores timings only, never message text.

Codex receives model-facing timing context and the end-of-session summary from
its hooks. It has no Claude-style `MessageDisplay` event, so the visual marker
is available in Claude Code but not in Codex.
