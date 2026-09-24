#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

[[ "$(uname -s)" == "Darwin" ]] || { echo "install.sh must run on macOS." >&2; exit 1; }
[[ "${EUID}" -ne 0 ]] || { echo "Run ./install.sh as your normal user; it will request sudo." >&2; exit 1; }
[[ -d dist/deadlock.app && -x dist/bedtimelockd ]] || { echo "Build artifacts missing. Run ./build.sh first." >&2; exit 1; }

for plist in \
  LaunchDaemons/com.deadlock.daemon.plist \
  LaunchDaemons/com.deadlock.watchdog.plist \
  LaunchAgents/com.deadlock.menubar.plist
do
  plutil -lint "$plist"
done

UID_NOW="$(id -u)"
USER_AGENT_DIR="$HOME/Library/LaunchAgents"
USER_AGENT="$USER_AGENT_DIR/com.deadlock.menubar.plist"

echo "Installing deadlock. sudo is required for root enforcement components."
sudo -v

# Stop watchdog first so an intentional update cannot race its repair logic.
sudo launchctl bootout system/com.deadlock.watchdog 2>/dev/null || true
sudo launchctl bootout system/com.deadlock.daemon 2>/dev/null || true
launchctl bootout "gui/$UID_NOW/com.deadlock.menubar" 2>/dev/null || true
pkill -x deadlock 2>/dev/null || true

sudo mkdir -p \
  /Library/PrivilegedHelperTools \
  /Library/LaunchDaemons \
  "/Library/Application Support/deadlock" \
  /var/db/deadlock
sudo chmod 700 "/Library/Application Support/deadlock" /var/db/deadlock
sudo chown root:wheel "/Library/Application Support/deadlock" /var/db/deadlock
mkdir -p "$USER_AGENT_DIR"

# Migrate the old bundle name away. The internal SwiftPM executable remains
# The SwiftPM target is BedtimeLock, but the installed executable and app are both named deadlock.
sudo rm -rf /Applications/BedtimeLock.app /Applications/deadlock.app
sudo /usr/bin/ditto dist/deadlock.app /Applications/deadlock.app

sudo install -o root -g wheel -m 755 \
  dist/bedtimelockd \
  /Library/PrivilegedHelperTools/bedtimelockd
sudo install -o root -g wheel -m 644 \
  LaunchDaemons/com.deadlock.daemon.plist \
  /Library/LaunchDaemons/com.deadlock.daemon.plist
sudo install -o root -g wheel -m 644 \
  LaunchDaemons/com.deadlock.watchdog.plist \
  /Library/LaunchDaemons/com.deadlock.watchdog.plist

# Independent recovery copies.
sudo install -o root -g wheel -m 755 \
  dist/bedtimelockd \
  /var/db/deadlock/bedtimelockd.backup
sudo install -o root -g wheel -m 644 \
  LaunchDaemons/com.deadlock.daemon.plist \
  /var/db/deadlock/com.deadlock.daemon.plist
sudo install -o root -g wheel -m 644 \
  LaunchDaemons/com.deadlock.watchdog.plist \
  /var/db/deadlock/com.deadlock.watchdog.plist

# Compatibility recovery copies for older watchdog builds.
sudo install -o root -g wheel -m 644 \
  LaunchDaemons/com.deadlock.daemon.plist \
  "/Library/Application Support/deadlock/com.deadlock.daemon.plist"
sudo install -o root -g wheel -m 644 \
  LaunchDaemons/com.deadlock.watchdog.plist \
  "/Library/Application Support/deadlock/com.deadlock.watchdog.plist"

install -m 644 LaunchAgents/com.deadlock.menubar.plist "$USER_AGENT"

# This Mac's xattr implementation does not support -r.
for path in \
  /Library/PrivilegedHelperTools/bedtimelockd \
  /Library/LaunchDaemons/com.deadlock.daemon.plist \
  /Library/LaunchDaemons/com.deadlock.watchdog.plist \
  /var/db/deadlock/bedtimelockd.backup \
  /var/db/deadlock/com.deadlock.daemon.plist \
  /var/db/deadlock/com.deadlock.watchdog.plist
do
  sudo xattr -d com.apple.quarantine "$path" 2>/dev/null || true
done
xattr -d com.apple.quarantine "$USER_AGENT" 2>/dev/null || true
sudo find /Applications/deadlock.app -exec xattr -d com.apple.quarantine {} \; 2>/dev/null || true

sudo plutil -lint /Library/LaunchDaemons/com.deadlock.daemon.plist
sudo plutil -lint /Library/LaunchDaemons/com.deadlock.watchdog.plist
plutil -lint "$USER_AGENT"

# Root enforcement starts first and survives independently of the menu UI.
sudo launchctl bootstrap system /Library/LaunchDaemons/com.deadlock.daemon.plist
sudo launchctl bootstrap system /Library/LaunchDaemons/com.deadlock.watchdog.plist
sudo launchctl kickstart -k system/com.deadlock.daemon

# KeepAlive makes the tiny menu item consistently present. Quitting/crashing the
# menu process simply causes launchd to bring it back; this does not affect root enforcement.
launchctl bootstrap "gui/$UID_NOW" "$USER_AGENT"
launchctl kickstart -k "gui/$UID_NOW/com.deadlock.menubar"

echo
echo "deadlock installed."
echo "  App:    /Applications/deadlock.app"
echo "  Daemon: root enforcement active independently"
echo "  Menu:   launch-at-login + KeepAlive"
echo
echo "Daemon status:"
sudo launchctl print system/com.deadlock.daemon 2>/dev/null | \
  grep -E 'state =|pid =|last exit code' | head -10 || true
echo
echo "Menu status:"
launchctl print "gui/$UID_NOW/com.deadlock.menubar" 2>/dev/null | \
  grep -E 'state =|pid =|last exit code' | head -10 || true
