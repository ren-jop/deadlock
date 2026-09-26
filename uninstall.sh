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

# Restore Chrome's pre-Deadlock URLBlocklist before deleting Deadlock state.
sudo python3 - <<'PY'
import json
import plistlib
from pathlib import Path

state_path = Path('/Library/Application Support/deadlock/browser-policy-state.json')
if state_path.exists():
    try:
        snapshot = json.loads(state_path.read_text())
        username = snapshot.get('username')
        if username:
            policy = Path('/Library/Managed Preferences') / username / 'com.google.Chrome.plist'
            values = {}
            if policy.exists():
                with policy.open('rb') as fh:
                    values = plistlib.load(fh)
            original = snapshot.get('chromeURLBlocklist', None)
            if original is None:
                values.pop('URLBlocklist', None)
            else:
                values['URLBlocklist'] = original
            if values:
                policy.parent.mkdir(parents=True, exist_ok=True)
                with policy.open('wb') as fh:
                    plistlib.dump(values, fh)
            elif policy.exists():
                policy.unlink()

        if username:
            helium = Path('/Library/Managed Preferences') / username / 'net.imput.helium.plist'
            hvals = {}
            if helium.exists():
                with helium.open('rb') as fh:
                    hvals = plistlib.load(fh)
            if snapshot.get('heliumCaptured') is True:
                original = snapshot.get('heliumURLBlocklist', None)
                if original is None:
                    hvals.pop('URLBlocklist', None)
                else:
                    hvals['URLBlocklist'] = original
                if hvals:
                    helium.parent.mkdir(parents=True, exist_ok=True)
                    with helium.open('wb') as fh:
                        plistlib.dump(hvals, fh)
                elif helium.exists():
                    helium.unlink()

        firefox = Path('/Library/Preferences/org.mozilla.firefox.plist')
        fvals = {}
        if firefox.exists():
            with firefox.open('rb') as fh:
                fvals = plistlib.load(fh)

        if snapshot.get('firefoxFlattenedWebsiteFilterBlockCaptured') is True:
            original = snapshot.get('firefoxFlattenedWebsiteFilterBlock', None)
            if original is None:
                fvals.pop('WebsiteFilter__Block', None)
            else:
                fvals['WebsiteFilter__Block'] = original

        if snapshot.get('firefoxEnterprisePoliciesEnabledCaptured') is True:
            original = snapshot.get('firefoxEnterprisePoliciesEnabled', None)
            if original is None:
                fvals.pop('EnterprisePoliciesEnabled', None)
            else:
                fvals['EnterprisePoliciesEnabled'] = bool(original)

        if fvals:
            with firefox.open('wb') as fh:
                plistlib.dump(fvals, fh)
        elif firefox.exists():
            firefox.unlink()
    except Exception as exc:
        print(f"warning: could not restore browser policy: {exc}")
PY

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
