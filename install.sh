#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
UID_NOW="$(id -u)"
AGENT_PLIST="$HOME/Library/LaunchAgents/com.deadlock.menubar.plist"
SUPPORT="/Library/Application Support/deadlock"
RECOVERY="/var/db/deadlock"

fail() { echo "error: $*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || fail "Deadlock supports macOS only."
[[ "$(uname -m)" == "arm64" ]] || fail "Deadlock currently supports Apple Silicon Macs."
[[ "$(id -u)" -ne 0 ]] || fail "Run ./install.sh as your normal user; it will request sudo when needed."
command -v xcrun >/dev/null 2>&1 || fail "Install Apple's Command Line Tools first: xcode-select --install"
xcrun --find swift >/dev/null 2>&1 || fail "Swift was not found. Install Apple's Command Line Tools: xcode-select --install"

cd "$ROOT"

echo "== Deadlock v1.3.0 preview =="
echo "Building the current repository source..."
./build.sh

[[ -d "$ROOT/dist/deadlock.app" ]] || fail "Build did not produce dist/deadlock.app."
[[ -x "$ROOT/dist/bedtimelockd" ]] || fail "Build did not produce dist/bedtimelockd."

echo "Stopping the previous installation..."
launchctl bootout "gui/$UID_NOW/com.deadlock.menubar" 2>/dev/null || true
sudo launchctl bootout system/com.deadlock.watchdog 2>/dev/null || true
sudo launchctl bootout system/com.deadlock.daemon 2>/dev/null || true

echo "Installing app and privileged components..."
sudo mkdir -p /Library/PrivilegedHelperTools /Library/LaunchDaemons "$SUPPORT" "$RECOVERY"
mkdir -p "$HOME/Library/LaunchAgents"

sudo rm -rf /Applications/deadlock.app
sudo /usr/bin/ditto "$ROOT/dist/deadlock.app" /Applications/deadlock.app
sudo install -m 755 "$ROOT/dist/bedtimelockd" /Library/PrivilegedHelperTools/bedtimelockd

sudo install -m 644   "$ROOT/LaunchDaemons/com.deadlock.daemon.plist"   /Library/LaunchDaemons/com.deadlock.daemon.plist
sudo install -m 644   "$ROOT/LaunchDaemons/com.deadlock.watchdog.plist"   /Library/LaunchDaemons/com.deadlock.watchdog.plist
install -m 644 "$ROOT/LaunchAgents/com.deadlock.menubar.plist" "$AGENT_PLIST"

# Keep last-known-good copies for the watchdog/recovery path without touching
# the signed policy/state files that may already exist in Application Support.
sudo install -m 755 "$ROOT/dist/bedtimelockd" "$RECOVERY/bedtimelockd.backup"
sudo install -m 644   "$ROOT/LaunchDaemons/com.deadlock.daemon.plist"   "$SUPPORT/com.deadlock.daemon.plist"
sudo install -m 644   "$ROOT/LaunchDaemons/com.deadlock.watchdog.plist"   "$SUPPORT/com.deadlock.watchdog.plist"
sudo install -m 644   "$ROOT/LaunchDaemons/com.deadlock.daemon.plist"   "$RECOVERY/com.deadlock.daemon.plist"
sudo install -m 644   "$ROOT/LaunchDaemons/com.deadlock.watchdog.plist"   "$RECOVERY/com.deadlock.watchdog.plist"

sudo chown root:wheel /Library/PrivilegedHelperTools/bedtimelockd
sudo chown root:wheel   /Library/LaunchDaemons/com.deadlock.daemon.plist   /Library/LaunchDaemons/com.deadlock.watchdog.plist
sudo chown -R root:wheel "$SUPPORT" "$RECOVERY"
sudo chmod 700 "$SUPPORT" "$RECOVERY"

echo "Starting enforcement..."
sudo launchctl enable system/com.deadlock.daemon 2>/dev/null || true
sudo launchctl enable system/com.deadlock.watchdog 2>/dev/null || true
launchctl enable "gui/$UID_NOW/com.deadlock.menubar" 2>/dev/null || true

sudo launchctl bootstrap system /Library/LaunchDaemons/com.deadlock.daemon.plist
sudo launchctl bootstrap system /Library/LaunchDaemons/com.deadlock.watchdog.plist
launchctl bootstrap "gui/$UID_NOW" "$AGENT_PLIST"

sudo launchctl kickstart -k system/com.deadlock.daemon
sudo launchctl kickstart -k system/com.deadlock.watchdog
launchctl kickstart -k "gui/$UID_NOW/com.deadlock.menubar"

sleep 1
sudo launchctl print system/com.deadlock.daemon >/dev/null   || fail "The privileged daemon did not start."
launchctl print "gui/$UID_NOW/com.deadlock.menubar" >/dev/null   || fail "The menu-bar helper did not start."

echo
echo "Deadlock v1.3.0 installed from the current source tree."
echo "Chrome, Helium and Firefox YouTube blocking use native browser policy. Safari uses a user-session guard and may request one-time Accessibility permission so only Safari tabs are closed.\n"
echo "IINA is not automated or DNS-blocked."
echo "Diagnostics: bash $ROOT/deadlockctl web"
