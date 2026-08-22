#!/usr/bin/env bash
# Regenerate the screenshots (and the hero animation) in assets/.
#
#   bash tools/screenshots/make.sh            every shot
#   bash tools/screenshots/make.sh doctor     just the doctor shot
#
# hero and picker each drive a real Claude Code session -- a working login,
# tokens spent, and however long the model takes to answer. wizard, doctor,
# stats, markers and session run local scripts only and are free and offline.
# Plain `make.sh` with no argument therefore spends two real sessions every
# time it runs; pass a single shot's name if that is not what you want.
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
