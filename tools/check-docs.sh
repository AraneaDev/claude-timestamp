#!/usr/bin/env bash
# Guard against the README drifting away from the code.
#
# Three ways it goes stale, all of them silent: a setting gets added and never
# documented, the assertion count in the README stops matching the suite, and an
# image gets renamed out from under a link. Each is cheap to check and annoying
# to notice by hand.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

status=0
note() { printf '  %s\n' "$*"; }

echo "settings documented"
# Keys the loader actually understands, taken from its own case statement.
code_keys="$(sed -n 's/^      \([A-Z_]*\)).*CT_.*=.*$/\1/p' hooks/scripts/lib/config.sh | sort -u)"
# Keys the README's settings table lists.
# shellcheck disable=SC2016  # the backticks are markdown, not a subshell
doc_keys="$(sed -n 's/^| `\([A-Z_]*\)` |.*/\1/p' README.md | sort -u)"

missing="$(comm -23 <(printf '%s\n' "$code_keys") <(printf '%s\n' "$doc_keys"))"
extra="$(comm -13 <(printf '%s\n' "$code_keys") <(printf '%s\n' "$doc_keys"))"

if [ -n "$missing" ]; then
  note "NOT in the README: $(printf '%s' "$missing" | tr '\n' ' ')"
  status=1
fi
if [ -n "$extra" ]; then
  note "in the README but not read by the loader: $(printf '%s' "$extra" | tr '\n' ' ')"
  status=1
fi
[ "$status" -eq 0 ] && note "all $(printf '%s\n' "$code_keys" | wc -l | tr -d ' ') settings are documented"

echo "assertion count"
actual="$(bash tests/run.sh 2>/dev/null | sed -n 's/^\([0-9]*\) passed.*/\1/p' | tail -1)"
claimed="$(sed -n 's/.*# \([0-9]*\) assertions.*/\1/p' README.md | head -1)"
if [ -z "$actual" ]; then
  note "could not read a count out of the test run"
  status=1
elif [ "$actual" != "$claimed" ]; then
  note "README says $claimed assertions, the suite reports $actual"
  status=1
else
  note "README and the suite agree on $actual assertions"
fi

echo "version agreement"
# Three files carry the version, and release-please updates all of them. If
# they ever disagree, an install and a release would claim different things.
plugin_version="$(jq -r .version .claude-plugin/plugin.json)"
file_version="$(tr -d '[:space:]' < version.txt)"
manifest_version="$(jq -r '."."' .release-please-manifest.json)"
if [ "$plugin_version" = "$file_version" ] && [ "$plugin_version" = "$manifest_version" ]; then
  note "plugin.json, version.txt and the release manifest all say $plugin_version"
else
  note "disagreement: plugin.json=$plugin_version version.txt=$file_version manifest=$manifest_version"
  status=1
fi

echo "linked images"
while read -r img; do
  if [ -f "$img" ]; then
    note "$img"
  else
    note "MISSING $img"
    status=1
  fi
done < <(grep -o '](assets/[^)]*)' README.md | tr -d '](' | sed 's/)$//')

echo
if [ "$status" -eq 0 ]; then echo "docs are in step with the code"; else echo "docs need updating"; fi
exit "$status"
