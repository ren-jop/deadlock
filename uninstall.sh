#!/bin/bash
set -euo pipefail
APP_BIN="/Applications/deadlock.app/Contents/MacOS/deadlock"
UID_NOW="$(id -u)"

if [[ ! -x "$APP_BIN" ]]; then
  echo "deadlock is not installed, so the cooldown cannot be verified through the daemon." >&2
  exit 1
fi

set +e
STATUS="$($APP_BIN --ipc uninstall-status 2>&1)"
RC=$?
set -e

if [[ $RC -ne 0 ]]; then
  echo "$STATUS"
  echo
  echo "Starting (or confirming) the 24-hour uninstall cooldown..."
  "$APP_BIN" --ipc uninstall-request || true
  exit 1
fi

if [[ "$STATUS" != *"READY"* ]]; then
  echo "$STATUS"
  exit 1
fi

echo "Cooldown complete. Removing deadlock..."

# Remove only sections owned by deadlock from /etc/hosts before stopping enforcement.
sudo python3 - <<'PY'
from pathlib import Path
p = Path('/etc/hosts')
text = p.read_text()
markers = [
    ('# BEGIN DEADLOCK ADULT PROTECTION', '# END DEADLOCK ADULT PROTECTION'),
    ('# BEGIN DEADLOCK DISTRACTIONS', '# END DEADLOCK DISTRACTIONS'),
    ('# BEGIN DEADLOCK WEB PROTECTION', '# END DEADLOCK WEB PROTECTION'),
]
for begin, end in markers:
    while begin in text:
        a = text.find(begin)
        b = text.find(end, a + len(begin))
        if b < 0:
            text = text[:a]
            break
        b += len(end)
        text = text[:a] + text[b:]
p.write_text(text.strip() + '\n')
PY
sudo /usr/bin/dscacheutil -flushcache 2>/dev/null || true
sudo /usr/bin/killall -HUP mDNSResponder 2>/dev/null || true

launchctl bootout "gui/$UID_NOW/com.deadlock.menubar" 2>/dev/null || true
sudo launchctl bootout system/com.deadlock.watchdog 2>/dev/null || true
sudo launchctl bootout system/com.deadlock.daemon 2>/dev/null || true

rm -f "$HOME/Library/LaunchAgents/com.deadlock.menubar.plist"
sudo rm -f /Library/LaunchDaemons/com.deadlock.daemon.plist /Library/LaunchDaemons/com.deadlock.watchdog.plist
sudo rm -f /Library/PrivilegedHelperTools/bedtimelockd
sudo rm -rf "/Library/Application Support/deadlock" /var/db/deadlock
sudo rm -rf /Applications/deadlock.app /Applications/BedtimeLock.app
sudo rm -f /var/run/deadlock.sock

echo "deadlock removed."
