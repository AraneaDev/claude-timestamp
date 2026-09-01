# Changelog

## [0.0.15](https://github.com/AraneaDev/claude-timestamp/compare/v0.0.14...v0.0.15) (2026-09-01)


### Fixes

* keep a leading code fence at the start of its line ([#46](https://github.com/AraneaDev/claude-timestamp/issues/46)) ([07f11ca](https://github.com/AraneaDev/claude-timestamp/commit/07f11ca5439b623606f4d325d2ca16d48c32035a))

## [0.0.14](https://github.com/AraneaDev/claude-timestamp/compare/v0.0.13...v0.0.14) (2026-09-01)


### Documentation

* link the project site from the readme ([#45](https://github.com/AraneaDev/claude-timestamp/issues/45)) ([17c7d16](https://github.com/AraneaDev/claude-timestamp/commit/17c7d166b390faec55cb1dbb2c0ca69db97f26af))
* point the badge at the renamed /tools section ([#43](https://github.com/AraneaDev/claude-timestamp/issues/43)) ([d176409](https://github.com/AraneaDev/claude-timestamp/commit/d176409cfb1fcd02cfac37e7b014081e6f2d4326))

## [0.0.13](https://github.com/AraneaDev/claude-timestamp/compare/v0.0.12...v0.0.13) (2026-08-30)


### Documentation

* name the SSH clone failure in the install section ([#41](https://github.com/AraneaDev/claude-timestamp/issues/41)) ([4d7a432](https://github.com/AraneaDev/claude-timestamp/commit/4d7a4326009ba265fff06b65966836048734ab56))

## [0.0.12](https://github.com/AraneaDev/claude-timestamp/compare/v0.0.11...v0.0.12) (2026-08-28)


### Continuous integration

* move off the actions still running on Node 20 ([394afba](https://github.com/AraneaDev/claude-timestamp/commit/394afbae929cecbda15515b79ee4328769a822f4))

## [0.0.11](https://github.com/AraneaDev/claude-timestamp/compare/v0.0.10...v0.0.11) (2026-08-28)


### Documentation

* point at the site's marketplace ([0b9a3a7](https://github.com/AraneaDev/claude-timestamp/commit/0b9a3a7cda877c7e5377ae25c64b39f88cb02b3b))

## [0.0.10](https://github.com/AraneaDev/claude-timestamp/compare/v0.0.9...v0.0.10) (2026-08-27)


### Documentation

* link the README to the project page ([939230b](https://github.com/AraneaDev/claude-timestamp/commit/939230b106e1d48683ef4ce65e2b966a6c4d3420))

## [0.0.9](https://github.com/AraneaDev/claude-timestamp/compare/v0.0.8...v0.0.9) (2026-08-27)


### Tests

* measure the hook, not the harness, in the turn-accounting timings ([1ce5d21](https://github.com/AraneaDev/claude-timestamp/commit/1ce5d212a01027d30c74713dd41c4a8e57a847a3))

## [0.0.8](https://github.com/AraneaDev/claude-timestamp/compare/v0.0.7...v0.0.8) (2026-08-26)


### Features

* record which client ran, and whether a marker was drawn ([e81d077](https://github.com/AraneaDev/claude-timestamp/commit/e81d077fd37e4f9d9faced5d90e3203ed1a86fe5))

## [0.0.7](https://github.com/AraneaDev/claude-timestamp/compare/v0.0.6...v0.0.7) (2026-08-22)


### Documentation

* describe what the plugin grew into ([#28](https://github.com/AraneaDev/claude-timestamp/issues/28)) ([9a12659](https://github.com/AraneaDev/claude-timestamp/commit/9a126596d075807290fa9a604fea4a366a68d871))

## [0.0.6](https://github.com/AraneaDev/claude-timestamp/compare/v0.0.5...v0.0.6) (2026-08-22)

Closes all 21 findings from a whole-codebase logic, security and performance
audit, and adds a configurable marker. Squashed from 74 commits on
`feat/payload-harvest`; the sections below are those commits' own subjects.

### Features

* close a turn on Stop instead of guessing from messages
* render the marker from a template
* add MARKER and the three part colours
* draw the marker from MARKER
* name a few marker looks and prove what they render
* pick a marker look without leaving Claude Code
* set the marker layout from the terminal too
* switch screenshots to lossless WebP and add marker/session shots

### Fixes

* spell the tool-log field separator as an escape sequence
* count tool failures by appending, not by incrementing a counter
* stamp .last unconditionally so IDLE_AFTER=0 doesn't hide turn reconciliation
* let an absent index fall through instead of being treated as a later batch
* stop doctor claiming tool timing loses sub-second precision
* read duration_ms as decimal and close four review gaps
* stop the marker renderer aborting under set -e, and reject nested groups
* stop the timestamp marker showing as literal escape codes in VS Code
* stop doctor blaming the wrong thing when NO_COLOR also suppresses colour
* wire MARKER and the three part colours into --project
* stop the wizard screenshot rejecting its own write-confirmation answer
* close the whole-branch review's remaining gaps in MARKER and part colours
* restore the PreToolUse shim and close two marker/project gaps
* stop the lint-list check's glob match from crossing directories
* hoist the duplicated comment-paths regex into one variable
* close four gaps in the staged-script guard from review
* record sessions even when the summary is switched off
* stop the summary counting the same seconds as both waiting and away
* clear the staged away figure unconditionally, before any gate
* stop the wizard spinning forever on a timezone it will not accept
* guard the display-format re-ask loop against exhausted stdin too
* return one object from SessionStart instead of up to three
* keep session state in a directory only you own
* close the date-rollover write's bare mkdir in message-display.sh
* close the TOCTOU race and mode gap in ct_state_ready, and doctor()'s bare mkdir
* reject control characters in values, and drop readlink -f
* guard TZ against control characters, restore readlink -f with a fallback
* stamp history in the pinned zone, and refuse --project from home
* strengthen the --project home check and its test coverage
* resolve tool timing from the payload's project, not the process's
* let the master switch reach the staged tool-timing flag
* reclaim an orphaned history-trim lock instead of losing HISTORY_LIMIT forever
* quote config values that need it, refuse a history limit of zero
* stop write_project_config re-quoting a carried-forward value
* skip damaged rows instead of summing them
* refuse a symlinked state directory, and stop paying five forks to find out
* write TZ through conf_value like every other free-text value
* refuse an entry the mode check cannot confirm is a directory
* point the screenshot tool at the per-uid state directory
* make the suite and setup.sh run on macOS and Windows
* act on the CodeRabbit review
* harden the history lock and widen the fence check
* count fences with a state machine, not parity

### Performance

* decide in the shell whether a batch needs stamping
* gate tool timing on a glob, not a jq fork, per call
* take the redundant forks off the message path, lock the history trim

### Refactoring

* take tool durations from the payload instead of timing them
* drop the timing helpers nothing calls any more
* assign colour escapes instead of printing them
* move session state into lib/state.sh

### Documentation

* describe the hooks the plugin actually binds
* correct state.sh header's config.sh dependency claim
* correct the three stale descriptions and empty the baseline
* document the three behaviour changes a user can actually see

### Tests

* exercise the .closed guard in the Stop-then-SessionEnd case
* pin how message-display decides a batch is the first one
* lock in that colour helpers always return 0
* add the regression detector the tiling guard could not be
* make the wizard-EOF regression test discriminate crash from fix
* keep the attribution guard from disarming its own regression tests

### Continuous integration

* adopt the free shellcheck ratchets and check the lint list
* check the five drifts the audit found by hand
* syntax-check the screenshot tool and lint staged scripts

Full diff: [`v0.0.5...v0.0.6`](https://github.com/AraneaDev/claude-timestamp/compare/v0.0.5...v0.0.6) ·
squashed as [`b64c15c`](https://github.com/AraneaDev/claude-timestamp/commit/b64c15c31cce6de4d713c6b99b0a380851c29ac8) from [#26](https://github.com/AraneaDev/claude-timestamp/pull/26).

## [0.0.5](https://github.com/AraneaDev/claude-timestamp/compare/v0.0.4...v0.0.5) (2026-08-20)


### Features

* configure the plugin without running a shell script ([#24](https://github.com/AraneaDev/claude-timestamp/issues/24)) ([1a88f10](https://github.com/AraneaDev/claude-timestamp/commit/1a88f100c42d1f8d622c751df4be38d07e4be649))

## [0.0.4](https://github.com/AraneaDev/claude-timestamp/compare/v0.0.3...v0.0.4) (2026-08-19)


### Documentation

* correct the session summary example ([#22](https://github.com/AraneaDev/claude-timestamp/issues/22)) ([9991780](https://github.com/AraneaDev/claude-timestamp/commit/9991780f3f5a1d98951b6a51bd799c2948e1797b))

## [0.0.3](https://github.com/AraneaDev/claude-timestamp/compare/v0.0.2...v0.0.3) (2026-08-19)


### Documentation

* the release flow no longer needs a manual nudge ([#20](https://github.com/AraneaDev/claude-timestamp/issues/20)) ([7a55d85](https://github.com/AraneaDev/claude-timestamp/commit/7a55d8535d0a96309fcfd1a8f1ecf6ad81974f3d))

## [0.0.2](https://github.com/AraneaDev/claude-timestamp/compare/v0.0.1...v0.0.2) (2026-08-19)


### Continuous integration

* use RELEASE_PLEASE_TOKEN when it is available ([#17](https://github.com/AraneaDev/claude-timestamp/issues/17)) ([de2ba10](https://github.com/AraneaDev/claude-timestamp/commit/de2ba100cdde0568a2b606b19e1b93a981f3728e))

## 0.0.1 (2026-08-19)


### Features

* claude-timestamp, a configurable message timestamp plugin ([929b80e](https://github.com/AraneaDev/claude-timestamp/commit/929b80e930b40979845d9a8fa34f69a613b1bfc6))
* let a project carry its own settings ([#5](https://github.com/AraneaDev/claude-timestamp/issues/5)) ([616f302](https://github.com/AraneaDev/claude-timestamp/commit/616f302ba9b742aaa4c81bda98f48dfbd96b210d))
* optional per-tool timing, and fix the session waiting total ([547536f](https://github.com/AraneaDev/claude-timestamp/commit/547536f5b33ad1ab704277f73e6042b147c50284))
* record finished sessions, and report what they add up to ([#6](https://github.com/AraneaDev/claude-timestamp/issues/6)) ([6fc5602](https://github.com/AraneaDev/claude-timestamp/commit/6fc56023ad7dafbff504b4d20b5d5c3d5d86ee66))
* slow-turn colouring, idle gaps, session summary, and a doctor ([57b13b9](https://github.com/AraneaDev/claude-timestamp/commit/57b13b9246737e56eae721907d25ed4443581cac))
* validate the config, and stop claiming a restart is needed ([#4](https://github.com/AraneaDev/claude-timestamp/issues/4)) ([6049476](https://github.com/AraneaDev/claude-timestamp/commit/60494766a6adf2d021e17f3f148c77a521cb5482))


### Fixes

* honour UTC and GMT on platforms without a timezone database ([4aab768](https://github.com/AraneaDev/claude-timestamp/commit/4aab768963abc4e409f3cb973315ab2226b8f512))
* never render a pinned timezone this platform cannot resolve ([56bafd0](https://github.com/AraneaDev/claude-timestamp/commit/56bafd0c5ea15e2a784a2c7be1257b1b36e7d8ed))
* release the first version as 0.0.1, and keep bumps inside 0.0.x ([#10](https://github.com/AraneaDev/claude-timestamp/issues/10)) ([196f4ef](https://github.com/AraneaDev/claude-timestamp/commit/196f4eff232826d39abe9c49c28890bab072384e))


### Documentation

* add a README, screenshots, and a script that regenerates them ([3e509f8](https://github.com/AraneaDev/claude-timestamp/commit/3e509f8a9b6352cb689760f53cdf32d89e2b460e))
* give the README a header, badges, and a better reading order ([#14](https://github.com/AraneaDev/claude-timestamp/issues/14)) ([06c0344](https://github.com/AraneaDev/claude-timestamp/commit/06c0344120964f384c8f1a892d8d7e01bb9303f0))
* record that a Release PR starts without checks ([#12](https://github.com/AraneaDev/claude-timestamp/issues/12)) ([4288477](https://github.com/AraneaDev/claude-timestamp/commit/4288477f6b91ef87023b09cefcd549e75af90b75))


### Tests

* express clock-derived assertions as tolerances ([bc05a0f](https://github.com/AraneaDev/claude-timestamp/commit/bc05a0fae453115f3199195c73966e06150328f3))
* isolate every case, cover the gaps, and check the docs in CI ([#3](https://github.com/AraneaDev/claude-timestamp/issues/3)) ([b2f041f](https://github.com/AraneaDev/claude-timestamp/commit/b2f041f62968cbfc95ea7b7b92278b8a09ff9e26))


### Continuous integration

* run the test suite on Windows as well ([caf134c](https://github.com/AraneaDev/claude-timestamp/commit/caf134cd6128228fcc543bd52535d3065f7c6a38))
