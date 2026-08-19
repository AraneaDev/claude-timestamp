# Changelog

Maintained by release-please from the commit messages. Entries below this line
are generated; the first release was written by hand.

## 0.0.1 (2026-08-19)

First release.

### Features

- Local-time marker on every assistant message, in your own timezone or a
  pinned one, in four clock formats or any strftime string.
- Elapsed time per turn, measured from the prompt, with a configurable
  threshold past which the duration changes colour.
- A marker for breaks between messages, so a session returned to the next
  morning still reads in order, and the date on the first message after
  midnight.
- The local time each prompt was sent, given to Claude as context, separately
  configurable from what is drawn on screen.
- End-of-session summary: how long it ran, over how many turns, how much was
  spent waiting and how much away, optionally which tools were slowest and how
  many calls failed.
- A history of finished sessions and `--stats` to report over them. Timings
  only, no message text and no paths.
- Settings in `~/.claude/claude-timestamp.conf`, with a per-project layer in
  `.claude/claude-timestamp.conf` overriding individual keys.
- `/timestamps` to configure from inside Claude Code, an interactive wizard
  with a live preview for a terminal, and `--doctor` to explain why something
  is not working.
