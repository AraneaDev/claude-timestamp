---
name: time-awareness
description: Use when a claude-timestamp system reminder says how long a turn has run, that a tool call was slow, or that a conversation or project is resumed after a gap; when the user asks how long something took, when they started, or where their time went; and before writing a date into notes, memory, a commit or a document.
user-invocable: false
---

# Time awareness

claude-timestamp tells you about time in short system reminders. They state
facts and nothing else. This is what to do with them.

## The reminders

**`Message sent at local time 10:37:21 CEST, after a 3h break`** arrives with
every prompt. It is when the user pressed enter, not the time now.

**`Turn running 30m04s (prompt sent 10:37:21); now 11:07:25 CEST.`** means the
turn you are in has run that long without hearing from the user.

- Check that the work still matches what was asked. Drift costs less to catch
  now than at the end.
- From the second one onward, consider finishing the step you are on and
  reporting back instead of opening new scope. That is a judgement call: a
  long job the user asked you to run unattended should keep going.

**`That Bash call took 2m14s.`** means one call was slow. Before running the
same thing again:

- run it with `run_in_background` and keep working meanwhile,
- narrow it: one test file, one package, a filter, or
- reuse the output you already have, when nothing it depends on has changed.

**`Previous session in this project ended 14h ago (Thu 20:12:05).`** and
**`Resuming this conversation; last activity 14h ago (Thu 20:12:05).`** mean
that what you knew before the gap may be stale. Before building on it, check
what could have moved: the branch and `git status`, running servers, open
pull requests and CI runs, and files the user may have edited meanwhile.

## Time in general

- During a long turn, get the current time from `date`. The last stamp in the
  conversation is when the user spoke.
- Refer to earlier messages by the time on their stamp ("the change you asked
  for at 10:37") rather than "earlier" or "just now".
- Write absolute dates in anything that outlives the conversation: "Thursday"
  becomes 2026-09-10.
- Answer questions about duration from measurement, never from how long the
  conversation feels.

## Measuring

This session so far:

```bash
bash "${CLAUDE_SKILL_DIR}/../../hooks/scripts/setup.sh" --session
```

Recorded sessions, all of them, the last week, or one project:

```bash
bash "${CLAUDE_SKILL_DIR}/../../hooks/scripts/setup.sh" --stats
bash "${CLAUDE_SKILL_DIR}/../../hooks/scripts/setup.sh" --stats --since=7d
bash "${CLAUDE_SKILL_DIR}/../../hooks/scripts/setup.sh" --stats --project=NAME
```

Sessions carry a project name only when the user turned on `PROJECTS`;
otherwise they are listed as "(unnamed)". Tool timings are kept per tool name,
not per command, and only with `TOOL_TIMING` on. "How long did `npm test`
take" therefore has an answer only in the slow-call reminders already in this
conversation.
