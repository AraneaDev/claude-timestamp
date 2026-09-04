#!/usr/bin/env bash
# Validate a commit or pull request title against Conventional Commits.
#
# The repository merges pull requests by squash, so the PR title becomes the
# commit subject on main, and release-please reads that subject to decide the
# next version. A title outside the convention produces a commit
# release-please silently ignores, and the release never happens -- PR #50's
# own title, "Record which project and which tools a session spent its time
# on", was exactly that shape. This is the one place the rule is written: the
# pr-title CI job and .githooks/commit-msg both call it, so neither can drift
# from the other.
#
# Usage: check-commit-title.sh <title>
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
title="${1:-}"

# git's own merge and revert subjects, and release-please's own release
# commits, are never meant to carry a type. "chore(main): release ..."
# already parses as a valid chore commit under the rule below -- this is a
# belt-and-braces exemption against a future release-please subject that
# does not, not a workaround for one that currently fails.
case "$title" in
  "Merge "* | "Revert "* | "chore(main): release "*) exit 0 ;;
esac

# The types release-please recognises, read from its own config so a type
# this check accepts and release-please does not -- exactly the failure this
# check exists to prevent -- cannot happen. jq is always installed by the job
# that calls this in CI; the commit-msg hook may run on a machine with none
# on PATH, so this falls back to a hardcoded copy of the same list for that
# one case. tools/check-docs.sh's "commit title types" gate asserts the
# fallback still matches release-please-config.json, so the copy cannot drift
# unnoticed.
config="$ROOT/release-please-config.json"
if command -v jq >/dev/null 2>&1 && [ -f "$config" ]; then
  types="$(jq -r '.packages["."]["changelog-sections"][].type' "$config")"
else
  # Kept in step with release-please-config.json's changelog-sections by
  # tools/check-docs.sh's "commit title types" gate.
  types="feat
fix
perf
refactor
test
docs
ci
style
chore"
fi

fail() {
  {
    echo "Not a Conventional Commits title: $title"
    echo
    echo "Accepted types: $(printf '%s' "$types" | tr '\n' ' ')"
    echo
    echo "Expected shape: type(scope)!: subject   (scope and ! are optional)"
    echo "Example:        fix(setup): accept a bare --marker="
  } >&2
  exit 1
}

case "$title" in
  *': '*) ;;
  *) fail ;;
esac

head="${title%%: *}"
subject="${title#*: }"

case "$head" in
  *'!') bare="${head%!}" ;;
  *) bare="$head" ;;
esac

case "$bare" in
  *'('*')')
    type="${bare%%(*}"
    rest="${bare#*(}"
    scope="${rest%)}"
    # Exactly one (scope): a stray paren inside the type or the scope, or
    # anything trailing the closing paren, means this was not that shape.
    case "$type" in *'('* | *')'*) fail ;; esac
    case "$scope" in *'('* | *')'*) fail ;; esac
    [ -n "$scope" ] || fail
    ;;
  *'('* | *')'*)
    fail
    ;;
  *)
    type="$bare"
    ;;
esac

case "$type" in
  '' | *[!a-z]*) fail ;;
esac

case "
$types
" in
  *"
$type
"*) ;;
  *) fail ;;
esac

trimmed="$(printf '%s' "$subject" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
[ -n "$trimmed" ] || fail

exit 0
