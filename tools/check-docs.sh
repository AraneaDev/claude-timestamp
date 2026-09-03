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

# Ids the tree is known to fail, so a check can land before its fix does.
KNOWN_GAPS="$(sed 's/#.*//' tools/known-gaps.txt 2>/dev/null | tr -d ' \t' | grep -v '^$' || true)"

# Record a check's outcome against the baseline. A known gap that fails is
# reported and tolerated; a known gap that passes is an error, because the
# line should have been deleted with the fix.
gate() {
  local id="$1" ok="$2" message="$3" known=0
  case "
$KNOWN_GAPS
" in *"
$id
"*) known=1 ;; esac

  if [ "$ok" -eq 1 ]; then
    if [ "$known" -eq 1 ]; then
      note "GAP CLOSED: $id now passes, delete it from tools/known-gaps.txt"
      status=1
    else
      note "$message"
    fi
  else
    if [ "$known" -eq 1 ]; then
      note "known gap: $id - $message"
    else
      note "$message"
      status=1
    fi
  fi
}

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
# shellcheck source=/dev/null
. hooks/scripts/lib/state.sh
values_ok=1
# A key whose values is not an array makes the extraction below fail mid-stream,
# and a process substitution discards the exit status of what filled it: the
# loop would see no rows and the check would report success on a broken schema.
# Reported as a finding first, and the extraction then takes only the arrays,
# the same shape the preset checks below already use.
while read -r key; do
  [ -n "$key" ] || continue
  note "the values field of $key is not an array"
  values_ok=0
  status=1
done < <(jq -r '.keys | to_entries[] | select(.value.values) |
                select((.value.values | type) != "array") | .key' schema.json)
while IFS="$(printf '\t')" read -r key validator value; do
  [ -n "$key" ] || continue
  if ! "$validator" "$value"; then
    note "$key lists '$value' but $validator rejects it"
    values_ok=0
    status=1
  fi
done < <(jq -r '.keys | to_entries[] | select(.value.values) |
                select((.value.values | type) == "array") |
                . as $e | .value.values[] |
                [$e.key, $e.value.validator, .] | @tsv' schema.json)
[ "$values_ok" -eq 1 ] && note "every listed value passes its validator"

# An alias is a value the validator accepts that the picker does not offer:
# ct_is_valid_color takes "off" and "grey" as well as "none" and "gray", and
# for a while schema.json said neither. commands/timestamps.md calls the schema
# the only source of truth about what a key may hold and tells the model to
# refuse anything it does not accept, so a user asking for grey was told grey
# is not a colour. Held to the same standard as `values`: listed here means the
# validator really takes it.
aliases_ok=1
# A key whose aliases is not an array makes the extraction below fail mid-stream,
# and a process substitution discards the exit status of what filled it: the
# loop would see no rows and the check would report success on a broken schema.
# Reported as a finding first, and the extraction then takes only the arrays,
# the same shape the preset checks below already use.
while read -r key; do
  [ -n "$key" ] || continue
  note "the aliases field of $key is not an array"
  aliases_ok=0
  status=1
done < <(jq -r '.keys | to_entries[] | select(.value.aliases) |
                select((.value.aliases | type) != "array") | .key' schema.json)
while IFS="$(printf '\t')" read -r key validator value; do
  [ -n "$key" ] || continue
  if ! "$validator" "$value"; then
    note "$key lists the alias '$value' but $validator rejects it"
    aliases_ok=0
    status=1
  fi
done < <(jq -r '.keys | to_entries[] | select(.value.aliases) |
                select((.value.aliases | type) == "array") |
                . as $e | .value.aliases[] |
                [$e.key, $e.value.validator, .] | @tsv' schema.json)
[ "$aliases_ok" -eq 1 ] && note "every listed alias passes its validator"

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

echo "setup flags agree with the schema"
# setup.sh drives its flags from one table, and that table names the validator
# each flag has to pass. It cannot read schema.json at runtime -- setup.sh has
# to work on a machine with no jq, which is the machine --doctor exists to
# diagnose -- so the agreement is asserted here instead.
#
# This is the check that would have caught --display and --context reaching the
# config file with no validator at all: a key with no row, a row for a key the
# schema does not have, or a row naming a validator the schema does not name,
# all fail here rather than in somebody's config file.
ft_ok=1
ft_detail=""
ft_rows="$(sed -n '/^CT_FLAG_TABLE="$/,/^"$/p' hooks/scripts/setup.sh | sed '1d;$d')"
if [ -z "$ft_rows" ]; then
  ft_ok=0
  ft_detail=" the flag table could not be read out of setup.sh;"
else
  # shellcheck disable=SC2034  # f_var and f_rest are read to consume the line
  while read -r f_flag f_key f_var f_validator f_rest; do
    [ -n "$f_flag" ] || continue
    want="$(jq -r --arg k "$f_key" '.keys[$k].validator // empty' schema.json)"
    if [ -z "$want" ]; then
      ft_ok=0; ft_detail="$ft_detail --$f_flag writes $f_key, which is not in schema.json;"
    elif [ "$want" != "$f_validator" ]; then
      ft_ok=0; ft_detail="$ft_detail --$f_flag validates with $f_validator, schema.json says $want;"
    fi
  done <<FT
$ft_rows
FT
  # ...and the other direction: a setting nobody can reach from the command
  # line is a setting the slash command can write and setup.sh cannot.
  while read -r s_key; do
    [ -n "$s_key" ] || continue
    printf '%s\n' "$ft_rows" | awk -v k="$s_key" '$2 == k { found = 1 } END { exit !found }' ||
      { ft_ok=0; ft_detail="$ft_detail $s_key has no flag;"; }
  done <<FS
$schema_keys
FS
fi
if [ "$ft_ok" -eq 1 ]; then
  gate setup-flag-table 1 "every flag validates with the validator schema.json names"
else
  gate setup-flag-table 0 "setup.sh's flag table drifts from schema.json:$ft_detail"
fi

echo "write_config writes every key the flag table names"
# write_project_config walks CT_FLAG_TABLE through _ct_flag_row_for_key, so
# every row it names reaches a project file automatically. write_config, the
# account-level writer, is a hand-written heredoc with no such loop -- a row
# can be added to the table and never make it into the heredoc, which is
# exactly what happened to PROJECTS: it parsed, validated and reported
# success while writing nothing, through three reviews and a full run of this
# file, because nothing compared the two lists.
#
# The heredoc's body is extracted by its own delimiters rather than by line
# number, so this keeps working as write_config grows.
wc_body="$(sed -n '/<<CONF$/,/^CONF$/p' hooks/scripts/setup.sh | sed '1d;$d')"
wc_written="$(printf '%s\n' "$wc_body" | grep -oE '^[A-Z_]+=' | sed 's/=$//' | sort -u)"
wc_missing=""
while read -r ft_key; do
  [ -n "$ft_key" ] || continue
  case "
$wc_written
" in
    *"
$ft_key
"*) ;;
    *) wc_missing="$wc_missing $ft_key" ;;
  esac
done < <(printf '%s\n' "$ft_rows" | awk '{ print $2 }')
if [ -n "$wc_missing" ]; then
  gate write-config-completeness 0 \
    "write_config's heredoc never writes:$wc_missing"
else
  gate write-config-completeness 1 \
    "write_config writes every key CT_FLAG_TABLE names"
fi

echo "show_config displays every key the flag table names"
# show_config is the second place, besides write_config, that claims to list
# every setting, and had the identical defect: PROJECTS reached
# CT_FLAG_TABLE and write_config's heredoc but never show_config, so --show
# could not confirm the setting took without reading the config file by
# hand. Modelled on the write-config-completeness gate above: extract
# show_config's own body by its braces, and check that each flag table
# row's variable is actually referenced somewhere in it. The boundary after
# the var name rules out CT_ELAPSED matching inside CT_ELAPSED_COLOR, and
# CT_HISTORY matching inside CT_HISTORY_LIMIT, which a plain substring test
# would miss.
sc_body="$(sed -n '/^show_config() {$/,/^}$/p' hooks/scripts/setup.sh | sed '1d;$d')"
sc_missing=""
while read -r ft_var; do
  [ -n "$ft_var" ] || continue
  printf '%s\n' "$sc_body" | grep -qE '\$\{?'"$ft_var"'([^A-Za-z0-9_]|$)' ||
    sc_missing="$sc_missing $ft_var"
done < <(printf '%s\n' "$ft_rows" | awk '{ print $3 }')
if [ -n "$sc_missing" ]; then
  gate show-config-completeness 0 \
    "show_config never displays:$sc_missing"
else
  gate show-config-completeness 1 \
    "show_config displays every key CT_FLAG_TABLE names"
fi

echo "every flag has a help line in usage()"
# The help-schema gate above checks that a handful of colour flags' help
# lines name the right placeholders; it has never checked that a flag has a
# help line at all. A design document for this branch claimed check-docs
# already covered a new CT_FLAG_TABLE key reaching --help, which is why
# nobody wrote this gate sooner -- the claim was false. Extract usage()'s
# own heredoc body and check that each flag table row's flag name is
# actually named there. The boundary after the flag rules out --history
# matching inside --history-limit, the same class of false pass the
# show-config-completeness gate above guards against for variable names.
us_body="$(sed -n "/cat <<'USAGE'\$/,/^USAGE\$/p" hooks/scripts/setup.sh | sed '1d;$d')"
us_missing=""
while read -r ft_flag; do
  [ -n "$ft_flag" ] || continue
  printf '%s\n' "$us_body" | grep -qE -- "--${ft_flag}([^A-Za-z0-9_-]|\$)" ||
    us_missing="$us_missing --$ft_flag"
done < <(printf '%s\n' "$ft_rows" | awk '{ print $1 }')
if [ -n "$us_missing" ]; then
  gate usage-completeness 0 \
    "usage() never mentions:$us_missing"
else
  gate usage-completeness 1 \
    "usage() has a help line for every flag CT_FLAG_TABLE names"
fi

echo "lint file list"
# The shellcheck and bash -n steps name their files by hand, so a new script
# is linted by nobody until someone remembers to add it. Compare the tracked
# set against the set CI actually names.
# Bounded by the step's own name and by the start of the next step or job,
# rather than by the first blank line: a blank line inside the step's comment
# block would silently end the range early and the check would then report a
# gap that is not there.
lint_listed="$(awk '
  /^      - name: shellcheck$/ { inblock = 1; next }
  inblock && /^      - name: / { inblock = 0 }
  inblock && /^  [a-z]/        { inblock = 0 }
  inblock                      { print }
' .github/workflows/ci.yml | grep -oE '[A-Za-z0-9_./*-]+\.sh|\.githooks/[a-z-]+' | sort -u)"
lint_tracked="$(git ls-files '*.sh' .githooks | sort -u)"

# A bash "case" pattern treats * as matching across "/", unlike real glob
# expansion (which never crosses a directory boundary without globstar). A
# naive `case "$f" in $pat)` would therefore call a script one directory
# deeper than an already-globbed pattern "covered", when CI would never
# actually lint it. Compare directory and basename separately instead: the
# directory must be exactly equal, and only the basename (which can never
# itself contain a "/") is allowed to carry a wildcard.
lint_missing=""
while read -r f; do
  [ -n "$f" ] || continue
  fdir="${f%/*}"
  [ "$fdir" = "$f" ] && fdir=""
  fbase="${f##*/}"
  covered=0
  while read -r pat; do
    [ -n "$pat" ] || continue
    pdir="${pat%/*}"
    [ "$pdir" = "$pat" ] && pdir=""
    pbase="${pat##*/}"
    [ "$fdir" = "$pdir" ] || continue
    case "$pbase" in
      '*'*)
        suffix="${pbase#\*}"
        case "$fbase" in *"$suffix") covered=1 ;; esac
        ;;
      *)
        [ "$fbase" = "$pbase" ] && covered=1
        ;;
    esac
    [ "$covered" -eq 1 ] && break
  done < <(printf '%s\n' "$lint_listed")
  [ "$covered" -eq 1 ] || lint_missing="$lint_missing $f"
done < <(printf '%s\n' "$lint_tracked")

if [ -n "$lint_missing" ]; then
  note "not covered by CI's shellcheck list:$lint_missing"
  status=1
else
  note "every tracked shell script is linted"
fi

echo "help text agrees with the schema"
# setup.sh's usage() is the only description of a setting that check-docs did
# not read, which is how --time-color came to say it colours %time when it
# also colours %date. Assert that every marker placeholder a schema key
# describes is named by the flag's help line.
hs_ok=1
hs_detail=""
while IFS="$(printf '\t')" read -r flag key; do
  [ -n "$flag" ] || continue
  help_line="$(sed -n "s/^  --${flag}=[A-Z]*  *//p" hooks/scripts/setup.sh | head -1)"
  describes="$(jq -r --arg k "$key" '.keys[$k].describes // ""' schema.json)"
  for ph in %time %elapsed %tool %date; do
    case "$describes" in
      *"$ph"*)
        case "$help_line" in
          *"$ph"*) ;;
          *) hs_ok=0; hs_detail="$hs_detail --$flag omits $ph;" ;;
        esac
        ;;
    esac
  done
done <<'EOF'
time-color	TIME_COLOR
elapsed-color	ELAPSED_COLOR
tool-color	TOOL_COLOR
marker	MARKER
EOF

if [ "$hs_ok" -eq 1 ]; then
  gate help-schema 1 "every flag's help names the placeholders its schema key does"
else
  gate help-schema 0 "help text drifts from schema.json:$hs_detail"
fi

echo "paths named in comments"
# A git hook in this repo names a directory under tools/ that has never
# existed, and tells contributors to point core.hooksPath at it. A path
# written into a comment is documentation, and it goes stale exactly as
# silently as the README.
#
# That path is deliberately not spelled out here as a real-looking one: this
# check would find it in its own comment and never stop calling it a gap.
#
# Python is scanned too, but not the virtualenv beside the screenshot tool:
# third-party package sources are full of paths that are real in THEIR repo and
# absent from this one, and every one of them would be reported as a gap here.
#
# One pattern, held in a variable and used twice. A second copy is a second
# thing to keep in step, and a contributor adding a directory to the
# alternation would update the copy they happened to find and leave the other
# scanning for the old set -- pattern drift, which is the failure this whole
# section exists to catch.
cp_re='(^|[^A-Za-z0-9_/.-])(hooks/scripts|tools|tests|assets|commands|docs|\.githooks|\.github|\.claude-plugin)/[A-Za-z0-9_./-]+'
cp_missing=""
while read -r path; do
  [ -n "$path" ] || continue
  [ -e "$path" ] || cp_missing="$cp_missing $path"
done < <(
  { grep -rhoE "$cp_re" \
         --include='*.sh' --include='*.md' --include='*.yml' --include='*.py' \
         --exclude-dir='.venv' --exclude-dir='__pycache__' \
         hooks tools tests commands .github .claude-plugin README.md CONTRIBUTING.md 2>/dev/null
    # Git hook scripts carry no extension, and --include excludes an
    # extensionless file even when it is named explicitly on the command line,
    # not only during -r traversal. Without this second call the check cannot
    # see the very file whose stale path it was written to catch, and would
    # report a clean bill that means nothing.
    grep -hoE "$cp_re" .githooks/pre-push .githooks/pre-commit 2>/dev/null
  } | sed 's/^[^A-Za-z0-9_/.-]*//' | sed 's/[.,:;)]*$//' | sort -u
)

if [ -n "$cp_missing" ]; then
  gate comment-paths 0 "named in a comment but absent:$cp_missing"
else
  gate comment-paths 1 "every repo path named in a comment exists"
fi

echo "hooks run under strict mode"
sm_missing=""
for f in hooks/scripts/*.sh; do
  case "$f" in */pre-tool-use.sh) continue ;; esac   # a deliberate bare no-op shim
  grep -q '^set -euo pipefail$' "$f" || sm_missing="$sm_missing $f"
done
if [ -n "$sm_missing" ]; then
  gate hook-strict-mode 0 "missing set -euo pipefail:$sm_missing"
else
  gate hook-strict-mode 1 "every hook sets -euo pipefail"
fi

echo "state files are cleaned up"
# ct_clear_state removes "$base" and "$base".*, so every suffix written
# anywhere is covered by construction. That only holds while the glob is there,
# and it is one edit away from becoming an explicit list that a new state file
# then falls off.
# shellcheck disable=SC2016  # this is a literal grep pattern, not a subshell
if grep -q 'rm -f "$base" "$base"\.\*' hooks/scripts/lib/*.sh; then
  gate state-glob 1 "ct_clear_state's glob covers every state suffix"
else
  gate state-glob 0 "ct_clear_state no longer removes \"\$base\".*"
fi

echo "no case statement inside a command substitution"
# bash 3.2 is what macOS ships, and it closes a command substitution on the
# first unparenthesised `)` in a case pattern. A `$(case ... in x) ... esac)`
# therefore makes the whole FILE fail to parse there, not just that line, so
# one of these takes every flag in setup.sh down with it. CI's macos runner
# catches it, but only after a push; this catches it before one.
# Whole-line comments are stripped before matching. The comment above spells
# the construct out on purpose, and a check that fails on its own explanation
# of itself teaches contributors to stop writing explanations.
# shellcheck disable=SC2016  # a literal grep pattern, not a subshell
b3_pat='[$][(].*case .* in [^(]'
b3_bad=""
for f in hooks/scripts/*.sh hooks/scripts/lib/*.sh tests/run.sh tools/*.sh; do
  [ -f "$f" ] || continue
  # grep -E rather than -qE: -q exits on the first match, the upstream grep
  # then takes SIGPIPE, and under `pipefail` the whole pipeline reports 141
  # instead of 0. That silently dropped a real hit from this very check.
  grep -v '^[[:space:]]*#' "$f" | grep -E "$b3_pat" >/dev/null && b3_bad="$b3_bad $f"
done
if [ -n "$b3_bad" ]; then
  gate bash3-case-subst 0 "case inside a command substitution, unparseable on bash 3.2:$b3_bad"
else
  gate bash3-case-subst 1 "no case statement sits inside a command substitution"
fi

echo "config values are written the same way by both writers"
# write_config and write_project_config produce the same file format, so a
# value that one of them quotes and the other interpolates raw is a round-trip
# bug waiting for the first setting whose value has an edge space. TZ was
# exactly that for a while: every other free-text key went through conf_value
# and TZ did not. There is no runtime test for this, because valid_tz blocks
# every TZ value that would show the difference -- so the invariant lives here,
# where it can actually fail.
# Each writer is checked in its own body. Scanning the whole file would let a
# correct line in write_config satisfy the check while write_project_config
# wrote the same key raw.
cv_missing=""
cv_wc="$(awk '/^write_config\(\) \{/,/^\}/' hooks/scripts/setup.sh)"
cv_wp="$(awk '/^write_project_config\(\) \{/,/^\}/' hooks/scripts/setup.sh)"
for key in TZ MARKER DISPLAY_FORMAT CONTEXT_FORMAT; do
  # shellcheck disable=SC2016  # a literal grep pattern, not a subshell
  printf '%s\n' "$cv_wc" | grep -E "^$key=\\\$\(conf_value " >/dev/null ||
    cv_missing="$cv_missing write_config:$key"
done
# write_project_config names its keys at run time, so there is one emit line to
# check rather than four: it must render through conf_value, and it must not
# also carry a raw "${key}=${value}" form that would bypass it. The carried
# branch is exempt -- it re-emits text conf_value already quoted once.
# shellcheck disable=SC2016  # literal source text to find, not an expansion
printf '%s\n' "$cv_wp" | grep -F 'conf_value "$value"' >/dev/null ||
  cv_missing="$cv_missing write_project_config:no-conf_value"
# shellcheck disable=SC2016  # literal source text to find, not an expansion
if [ "$(printf '%s\n' "$cv_wp" | grep -cF '${key}=${value}')" -gt 1 ]; then
  cv_missing="$cv_missing write_project_config:raw-emit"
fi
if [ -n "$cv_missing" ]; then
  gate conf-value-symmetry 0 "free-text keys interpolated without conf_value:$cv_missing"
else
  gate conf-value-symmetry 1 "every free-text config value is written through conf_value"
fi

echo "fenced code blocks carry a language"
# A bare ``` renders without highlighting and trips MD040 in any Markdown
# linter a contributor happens to run. Cheap to keep consistent, annoying to
# fix in bulk later. `text` is the right answer for terminal output.
fence_bad=""
for f in README.md CONTRIBUTING.md; do
  # A fence may be indented up to three spaces, may carry trailing whitespace,
  # and may use more than three backticks. Matching only a bare ``` at column 1
  # lets all three through untagged.
  n="$(awk '
    {
      line = $0
      sub(/^[ ]{0,3}/, "", line)
      sub(/[[:space:]]+$/, "", line)
      # Track the open fence and its length. Counting every fence-shaped line
      # as a toggle miscounts a tagged ````block whose CONTENT is a literal
      # ``` line: the inner one is text, not a closer, and treating it as one
      # flips the parity so the real closer looks like a bare opener.
      if (open) { if (line ~ /^`+$/ && length(line) >= fence_len) open = 0; next }
      if (line ~ /^`+$/ && length(line) >= 3) { open = 1; fence_len = length(line); b++ }
      else if (line ~ /^`{3,}[^`]/) { open = 1; match(line, /^`+/); fence_len = RLENGTH }
    }
    END { print b + 0 }' "$f")"
  [ "$n" -eq 0 ] || fence_bad="$fence_bad $f:$n"
done
if [ -n "$fence_bad" ]; then
  gate fenced-language 0 "fenced blocks with no language:$fence_bad"
else
  gate fenced-language 1 "every fenced code block names a language"
fi

echo "prose style"
ps_detail=""
for f in README.md CONTRIBUTING.md; do
  n="$(grep -c '—' "$f" || true)"
  [ "$n" = "0" ] || ps_detail="$ps_detail $f has $n em dash(es);"
  n="$(grep -icE '\b(we|our)\b' "$f" || true)"
  [ "$n" = "0" ] || ps_detail="$ps_detail $f has $n we/our self-reference(s);"
done
if [ -n "$ps_detail" ]; then
  gate prose-style 0 "house style:$ps_detail"
else
  gate prose-style 1 "README and CONTRIBUTING carry no em dashes and no we/our"
fi

echo "assertion count"
# Read BOTH numbers. A failing assertion lowers the passed count, so reading
# only "N passed" reports a broken suite as a stale README and sends whoever
# is looking to the wrong file. That happened: one flaky clock assertion showed
# up here as "the suite reports 608" and nothing said a test had failed.
tail_line="$(bash tests/run.sh 2>/dev/null | sed -n 's/^\([0-9]*\) passed, \([0-9]*\) failed.*/\1 \2/p' | tail -1)"
actual="${tail_line%% *}"
failed="${tail_line##* }"
claimed="$(sed -n 's/.*# \([0-9]*\) assertions.*/\1/p' README.md | head -1)"
if [ -z "$tail_line" ]; then
  note "could not read a count out of the test run"
  status=1
elif [ "$failed" != "0" ]; then
  note "the suite is failing: $failed assertion(s). Fix the suite before reading anything into the count."
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
elif [ "$failed" != "0" ]; then
  # Already reported above. Comparing a badge against a count depressed by a
  # failure would name the badge as the problem twice over.
  note "not compared: the suite is failing"
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
