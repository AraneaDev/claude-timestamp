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

echo "schema agrees with the loader"
schema_keys="$(jq -r '.keys | keys[]' schema.json | sort -u)"

s_missing="$(comm -23 <(printf '%s\n' "$code_keys") <(printf '%s\n' "$schema_keys"))"
s_extra="$(comm -13 <(printf '%s\n' "$code_keys") <(printf '%s\n' "$schema_keys"))"
if [ -n "$s_missing" ]; then
  note "NOT in schema.json: $(printf '%s' "$s_missing" | tr '\n' ' ')"
  status=1
fi
if [ -n "$s_extra" ]; then
  note "in schema.json but not read by the loader: $(printf '%s' "$s_extra" | tr '\n' ' ')"
  status=1
fi

# Defaults must match what ct_load_config actually sets. Only keys the loader
# understands are compared, so its internal CT_* scratch variables are skipped.
# The sed is scoped to ct_load_config's own body rather than the whole file:
# other functions assign CT_* variables of their own (the marker renderer
# assigns CT_MARKER, for instance), and an unscoped scan would read those as
# if they were defaults for a same-named schema key.
# A space separates key and value rather than a tab: BSD sed does not expand
# \t in a replacement, and every default here is a single token with no
# spaces, so a space is unambiguous (CT_TZ="" yields an empty want, which is
# correct -- its default is the empty string).
schema_defaults_ok=1
while read -r key want; do
  [ -n "$key" ] || continue
  case "$schema_keys" in *"$key"*) ;; *) continue ;; esac
  have="$(jq -r --arg k "$key" '.keys[$k].default' schema.json)"
  if [ "$want" != "$have" ]; then
    note "$key defaults to '$want' in the loader but '$have' in schema.json"
    schema_defaults_ok=0
    status=1
  fi
done < <(sed -n '/^ct_load_config() {/,/^}/{s/^  CT_\([A-Z_]*\)="\([^"]*\)".*/\1 \2/p}' hooks/scripts/lib/config.sh)
[ "$schema_defaults_ok" -eq 1 ] && note "every default matches the loader"

# Every enumerated value must actually pass the validator named for that key.
# Comparing against the validator itself rather than against its source text
# means a validator that changes shape cannot quietly pass this check.
# shellcheck source=/dev/null
. hooks/scripts/lib/config.sh
values_ok=1
while IFS="$(printf '\t')" read -r key validator value; do
  [ -n "$key" ] || continue
  if ! "$validator" "$value"; then
    note "$key lists '$value' but $validator rejects it"
    values_ok=0
    status=1
  fi
done < <(jq -r '.keys | to_entries[] | select(.value.values) |
                . as $e | .value.values[] |
                [$e.key, $e.value.validator, .] | @tsv' schema.json)
[ "$values_ok" -eq 1 ] && note "every listed value passes its validator"

# A preset that names a key the loader does not read, or a value its validator
# rejects, would write a config the plugin then silently ignores.
presets_ok=1

# A preset with no keys at all produces no rows below, so the loop cannot see
# it: jq would fail mid-stream inside a process substitution, whose exit status
# is discarded, and the check would report success on a broken schema.
while read -r preset; do
  [ -n "$preset" ] || continue
  note "preset $preset writes no keys"
  presets_ok=0
  status=1
done < <(jq -r '.presets // {} | to_entries[] |
                select((.value.set | type) != "object" or (.value.set | length) == 0) |
                .key' schema.json)

while IFS="$(printf '\t')" read -r preset key value; do
  [ -n "$preset" ] || continue
  validator="$(jq -r --arg k "$key" '.keys[$k].validator // empty' schema.json)"
  if [ -z "$validator" ]; then
    note "preset $preset sets $key, which is not in schema.json"
    presets_ok=0
    status=1
  elif ! "$validator" "$value"; then
    note "preset $preset sets $key=$value, which $validator rejects"
    presets_ok=0
    status=1
  fi
done < <(jq -r '.presets // {} | to_entries[] |
                .key as $p | (.value.set // {}) | to_entries[] |
                [$p, .key, .value] | @tsv' schema.json)
[ "$presets_ok" -eq 1 ] && note "every preset writes keys the loader reads"

# quieter/default/detailed are documented as writing an identical key set, so
# switching between them can never leave a setting behind from the one before.
# Nothing else enforces that claim.
q_keys="$(jq -r '.presets.quieter.set // {} | keys | sort | @csv' schema.json)"
d_keys="$(jq -r '.presets.default.set // {} | keys | sort | @csv' schema.json)"
t_keys="$(jq -r '.presets.detailed.set // {} | keys | sort | @csv' schema.json)"
if [ "$q_keys" = "$d_keys" ] && [ "$d_keys" = "$t_keys" ]; then
  note "quieter, default and detailed write the same key set"
else
  note "key sets differ: quieter=$q_keys default=$d_keys detailed=$t_keys"
  status=1
fi

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

echo "test count badge"
# The badge states a number, so it can drift the same way the code comment can.
badge_count="$(sed -n 's/.*badge\/tests-\([0-9]*\)%20passing.*/\1/p' README.md | head -1)"
if [ -z "$badge_count" ]; then
  note "no test-count badge found"
elif [ "$badge_count" != "$actual" ]; then
  note "the badge says $badge_count tests, the suite reports $actual"
  status=1
else
  note "the badge and the suite agree on $actual tests"
fi

echo "linked images"
while read -r img; do
  if [ -f "$img" ]; then
    note "$img"
  else
    note "MISSING $img"
    status=1
  fi
done < <( { grep -o '](assets/[^)]*)' README.md | tr -d '](' | sed 's/)$//'
            grep -o 'src="assets/[^"]*"' README.md | sed 's/src="//;s/"$//'
          } | sort -u )

echo
if [ "$status" -eq 0 ]; then echo "docs are in step with the code"; else echo "docs need updating"; fi
exit "$status"
