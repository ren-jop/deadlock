#!/bin/bash
set -euo pipefail
APP="/Applications/deadlock.app/Contents/MacOS/deadlock"
if [[ ! -x "$APP" ]]; then
  echo "deadlock is not installed at /Applications/deadlock.app" >&2
  exit 1
fi
"$APP" --ipc maintenance-unlock
echo "Settings are editable for this daemon session. Restarting bedtimelockd restores the normal guards."
