# Codex project guidance

This repository contains a Claude Code plugin and a Codex-compatible plugin
manifest. Keep the two integrations additive: Claude Code's hooks and
`MessageDisplay` marker are existing behavior and must remain intact.

When a claude-timestamp hook supplies a measured time, turn duration, slow-tool
note, or resumption note, use that value instead of estimating. Codex receives
the notes and session summary through lifecycle hooks; it cannot display the
per-message visual marker because Codex has no `MessageDisplay` event.

For timing reports, run the repository's CLI from the Git root:

```bash
bash "$(git rev-parse --show-toplevel)/hooks/scripts/setup.sh" --session
bash "$(git rev-parse --show-toplevel)/hooks/scripts/setup.sh" --stats
```

Use the `time-awareness` skill when it is available. `/timestamps` is the
Claude Code command; in Codex, configure with `setup.sh` or the bundled
`timestamps` skill.
