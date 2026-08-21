# Contributing

## Getting set up

The plugin itself needs only `bash` and `jq`. Working on it also wants
`shellcheck`, and the screenshot tooling wants Python.

```bash
git clone https://github.com/AraneaDev/claude-timestamp
cd claude-timestamp
cp .githooks/pre-commit .githooks/pre-push .git/hooks/
chmod +x .git/hooks/pre-commit .git/hooks/pre-push
```

The hooks are copied rather than reached through `core.hooksPath`, because a
tracked hook only exists in the working tree while a branch containing it is
checked out, so it would be missing on exactly the branches that predate it.
`pre-commit` refuses commits made directly on `main` and `pre-push` refuses
pushes to it. Both take `--no-verify` when you mean it.

## Checks

```bash
bash tests/run.sh          # the suite, no framework and no dependencies
bash tools/check-docs.sh   # the README against the code
shellcheck -S style -e SC1091 hooks/scripts/*.sh hooks/scripts/lib/*.sh tests/run.sh
```

All three run in CI, on Linux, macOS and Windows. macOS runs the suite twice,
the second time under `/bin/bash`, which is still 3.2, so the compatibility
claim in the README is tested rather than asserted.

`SC1091` is excluded because every hook resolves its library path at runtime,
which shellcheck cannot follow.

`tools/check-docs.sh` also holds a baseline, `tools/known-gaps.txt`, listing
checks the tree is known to fail. A listed check that passes is itself an
error, so a fix cannot land without the baseline being tidied. The file being
empty means every check is live.

## Working on it

Changes go through a pull request. `main` is protected and requires the six
checks to pass.

New behaviour needs a test. The suite resets the config and state directory
before each case, so nothing inherits anything from the case before it. Two
bugs came from that not being true, and both are guarded now.

Assertions about the clock need care. Recomputing `date` to compare against
output a hook has already produced races it by a second on a slow runner, which
is how two assertions first failed on Windows. Use a tolerance, or bracket the
call with two readings and accept either.

If the output changes, regenerate the screenshots:

```bash
bash tools/screenshots/make.sh
```

They are captured from the real programs rather than mocked up, so the hero
shot needs a working Claude Code login and spends tokens.

## Commit messages

[Conventional Commits](https://www.conventionalcommits.org/), which is what
release-please reads to work out the next version:

- `feat:` new behaviour
- `fix:` a bug fix
- `perf:` a performance change
- `refactor:` restructuring with no change in behaviour
- `test:` tests only
- `docs:` documentation only
- `ci:` continuous integration
- `chore:` tooling and housekeeping

Example: `feat: mark gaps between messages`

## Releases

Automated by [release-please](https://github.com/googleapis/release-please) via
`.github/workflows/release-please.yml`:

1. Write commits on `main` following the convention above.
2. release-please keeps a **Release PR** open and up to date, bumping
   `.claude-plugin/plugin.json`, `version.txt` and the release manifest, and
   writing `CHANGELOG.md`, all from those commits.
3. CI runs on the Release PR by itself, because the workflow opens it with the
   `RELEASE_PLEASE_TOKEN` secret. Review it and merge.
4. Merging that PR creates the `vX.Y.Z` tag and the GitHub Release, then the
   same workflow runs the tests, checks the docs, and asserts the tag matches
   the version it just released.

Tags are plain `vX.Y.Z`. Claude Code only looks for `{name}--v*` tags when it
resolves a plugin dependency pinned to a version range, and falls back to
copying the default branch when it finds none, so a normal install is
unaffected. If that resolution is ever wanted, the release job can push a
second tag in that form alongside this one.

Below `1.0.0` a feature bumps the patch number and a breaking change bumps the
minor one, so the shape of the configuration can settle without spending major
versions on it.

### If a Release PR turns up with no checks

That means the workflow fell back to the built-in `GITHUB_TOKEN`, which is what
happens when `RELEASE_PLEASE_TOKEN` is missing or has expired. GitHub does not
start workflows for events that token raises, and `main` requires those checks,
so the pull request cannot be merged as it stands.

Closing and reopening it raises the event under your own account and starts the
checks:

```bash
gh pr close <n> && gh pr reopen <n>
```

To fix it properly, replace the secret. Create a
[fine-grained token](https://github.com/settings/personal-access-tokens/new)
scoped to this repository with **Contents: read and write** and **Pull
requests: read and write**, then:

```bash
gh secret set RELEASE_PLEASE_TOKEN --repo AraneaDev/claude-timestamp
```

Fine-grained tokens expire, and this is how that expiry shows up. A GitHub App
token avoids it at the cost of more setup.

### Rules

Do not hand-edit versions or `CHANGELOG.md`, and do not hand-create tags. All
of it is managed by release-please. If a release needs extra narrative, edit
the Release PR description before merging it.
