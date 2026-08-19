#!/usr/bin/env bash
# Regenerate the screenshots in assets/.
#
#   bash tools/screenshots/make.sh            both shots
#   bash tools/screenshots/make.sh doctor     just the doctor shot
#
# The hero shot drives a real Claude Code session, so it needs a working login
# and it spends tokens. The doctor shot is free and offline.
#
# Dependencies go in a virtualenv beside this script rather than in the system
# python, which on most distributions refuses the install anyway (PEP 668).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
venv="$here/.venv"

if [ ! -x "$venv/bin/python" ]; then
  echo "creating virtualenv in $venv"
  python3 -m venv "$venv"
  "$venv/bin/pip" install --quiet --upgrade pip
  "$venv/bin/pip" install --quiet -r "$here/requirements.txt"
fi

exec "$venv/bin/python" "$here/screenshots.py" "${1:-all}"
