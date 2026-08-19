# Changelog

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
