## What changed

<!-- One or two sentences. What does this do that the repository did not do before? -->

## Why

<!-- The reason the change is worth making. Skip if it is obvious from the above. -->

## Checks

- [ ] `bash tests/run.sh` passes
- [ ] `shellcheck -S style -e SC1091 hooks/scripts/*.sh hooks/scripts/lib/*.sh tests/run.sh` is clean
- [ ] New behaviour has a test, or there is a note below saying why it does not
- [ ] Screenshots regenerated if the output changed (`bash tools/screenshots/make.sh`)
