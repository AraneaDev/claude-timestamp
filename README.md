<div align="center">

# Claude Timestamp

**Every message stamped with the time it happened and how long it took.**
**At the end, where the session's time actually went.**

[![Release](https://img.shields.io/github/v/release/AraneaDev/claude-timestamp)](https://github.com/AraneaDev/claude-timestamp/releases)
[![Tool page](https://img.shields.io/badge/tool%20page-aranea--development.nl-0b7285)](https://aranea-development.nl/en/tools/claude-timestamp)
[![CI](https://github.com/AraneaDev/claude-timestamp/actions/workflows/ci.yml/badge.svg)](https://github.com/AraneaDev/claude-timestamp/actions/workflows/ci.yml)
[![Tests](https://img.shields.io/badge/tests-1467%20passing-2b8a3e)](tests/run.sh)
[![Platform](https://img.shields.io/badge/platform-Linux%20%7C%20macOS%20%7C%20Windows-364fc7)](docs/troubleshooting.md#platform-notes)
[![Conventional Commits](https://img.shields.io/badge/commits-conventional-fe5196?logo=conventionalcommits&logoColor=white)](https://www.conventionalcommits.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)

<img src="assets/timestamps.webp" alt="A real Claude Code session, timestamps on assistant messages, with a slow turn highlighted" width="840">

<sub>Two fast turns render dim. The third crosses the slow threshold, so its duration is coloured and, with `TOOL_TIMING` on, named after the tool that caused it. Tool timing is off by default, so a plain install will not show this on its own. This is a real session played back at real speed. Nothing here is sped up or looped faster than it happened.</sub>

</div>

---

**TL;DR:** Claude Timestamp adds local time and turn duration to Claude Code's display. Its
plugin hook measures prompts, replies, gaps, and tool calls, then marks slow work on screen and
optionally sends concise timing context to Claude.

It puts your local time on every assistant message, shows how long each turn took, and tells
Claude when your prompt was sent, so a long conversation can be scanned, timed, and referred back
to.

Claude gets more than the clock, too. It hears when a turn has run long, when
one command was slow, and when a project or conversation is picked up after a
gap, and a skill the plugin ships tells it what each of those is a reason to
do.

There is nothing to set up. The defaults work as soon as it is installed, and
`/timestamps` changes them from inside Claude Code without restarting anything.

## What it does

- **Timestamps every message.** A marker like `[13:22:13]` in front of each
  assistant message, in your local time or a timezone you pin.
- **Shows how long a turn took.** `+2m14s` counts from the moment you pressed
  enter to the moment the reply appeared.
- **Highlights slow turns.** Once a turn passes a threshold you set, its
  duration changes colour so you notice it instead of reading past it. Turn on
  `TOOL_TIMING` and it names what made the turn slow, too:
  `[13:22:13 +2m14s · Bash 1m58s]`.
- **Marks where you stepped away.** A gap between messages is labelled, so a
  session you returned to the next morning still reads in order.
- **Tells Claude the time.** The model receives the local time each prompt was
  sent, a short note when a turn runs long or a tool call is slow, and, when a
  session starts, how long ago this project or conversation was last active.
  See [What Claude is told](docs/agent-notes.md). You can switch this off and
  keep the display-only marker.
- **Lets Claude answer time questions.** Ask how long you have been at it, or
  how much of it you spent waiting, and the bundled `time-awareness` skill
  answers from the measured session rather than a guess.
- **Summarises the session.** On exit: how long it ran, how many turns, how
  much of that you spent waiting, and how much you were away. Waiting and away
  never cover the same seconds, so the two add up to no more than the session
  itself. It can also list the slowest tools and the calls that failed.

```text
claude-timestamp: session lasted 1h30m over 12 turns, 24m18s of it waiting, 35m00s away.
slowest tools: Bash 41.2s (18 calls), WebFetch 8.1s (1 call), Read 2.0s (37 calls). 2 failed
```

The gap divider and closing summary appear in one screenshot from the same session
used for this example:

<p align="center">
  <img src="assets/session.webp" alt="An idle divider above a stamped message, and the end-of-session summary below it" width="700">
</p>

- **Keeps a running record.** Finished sessions are logged so you can see where
  the time actually goes.

Display is display only. The marker is drawn as messages render, so it never
enters the transcript and never reaches the model.

## Install

```bash
claude plugin marketplace add https://aranea-development.nl/plugins/marketplace.json
claude plugin install claude-timestamp@aranea
```

Hooks are bound when a session starts, so start a new session before markers
appear. An already-running session will not pick the plugin up.

### Where it works

This is a Claude Code plugin, and it runs wherever Claude Code itself runs: the
terminal, the IDE extensions, and the **Code** tab of the desktop app. The
**Chat** and **Cowork** tabs are not Claude Code. They have no hooks and no
display event to attach a marker to, so nothing here can reach them. Cloud
sessions on the web read hooks from the repository and from managed settings
rather than from your `~/.claude`, so a personal install does not apply there
either.

It also runs in Codex. What works depends on the client that runs the plugin,
not on the model: every model gets the same features in Claude Code, and the
same is true in Codex. Checked against Claude Code and Codex CLI 0.154.0.

| Feature | Claude Code | Codex | Note |
| --- | :---: | :---: | --- |
| Timestamp marker on each message | ✓ | ✗ | Codex has no event for drawing on a message |
| Idle divider and slow-turn colour | ✓ | ✗ | Drawn by the same marker |
| Prompt time told to Claude | ✓ | ✓ | |
| Turn-length and slow-tool notes | ✓ | ✓ | Codex timings are whole seconds |
| Resumption note, for a project or a conversation | ✓ | ✓ | |
| Note after a compaction | ✓ | ✓ | |
| Command memory and the usually-slow note | ✓ | ✓ | |
| Turn timeline, `--turns` | ✓ | ✓ | |
| A turn that ends in an API error recorded as `error` | ✓ | ✗ | Codex has no `StopFailure` event |
| Session summary at exit | ✓ | ✓ | Recorded in the history; `codex exec` does not display it |
| History and `--stats` | ✓ | ✓ | |
| `time-awareness` skill | ✓ | ✓ | |
| `/timestamps` command | ✓ | ✗ | Codex uses the `timestamps` skill or `setup.sh` |

## Further reading

- [Your Claude Code session has no clock](https://tim-schipper.nl/en/blog/claude-code-timestamps)

## License

MIT

---

Built by [Tim Schipper](https://tim-schipper.nl/en) and released as open source under
[Aranea Development](https://aranea-development.nl).
