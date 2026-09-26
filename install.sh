#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
UID_NOW="$(id -u)"
AGENT_PLIST="$HOME/Library/LaunchAgents/com.deadlock.menubar.plist"
SUPPORT="/Library/Application Support/deadlock"
RECOVERY="/var/db/deadlock"

fail() {
  echo "error: $*" >&2
  exit 1
}

wait_until_unloaded() {
  local target="$1"
  local attempt
  for attempt in {1..30}; do
    if ! launchctl print "$target" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

wait_until_unloaded_root() {
  local target="$1"
  local attempt
  for attempt in {1..30}; do
    if ! sudo launchctl print "$target" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

bootstrap_system_job() {
  local label="$1"
  local plist="$2"
  local target="system/$label"
  local output=""

  if sudo launchctl print "$target" >/dev/null 2>&1; then
    echo "  $label already loaded; restarting it."
    sudo launchctl kickstart -k "$target"
    return 0
  fi

  if output="$(sudo launchctl bootstrap system "$plist" 2>&1)"; then
    echo "  $label loaded."
    return 0
  fi

  echo "  First bootstrap of $label failed: $output"
  echo "  Clearing stale launchd state and retrying..."

  sudo launchctl bootout "$target" >/dev/null 2>&1 || true
  sudo launchctl bootout system "$plist" >/dev/null 2>&1 || true
  wait_until_unloaded_root "$target" || true
  sleep 0.3

  if output="$(sudo launchctl bootstrap system "$plist" 2>&1)"; then
    echo "  $label loaded after retry."
    return 0
  fi

  echo "  launchd rejected $label again: $output" >&2
  echo "  Installed plist:" >&2
  sudo plutil -p "$plist" >&2 || true
  echo "  Installed helper signature:" >&2
  sudo codesign --verify --verbose=2 /Library/PrivilegedHelperTools/bedtimelockd >&2 || true
  fail "Could not load $label. Run: sudo launchctl print $target"
}

bootstrap_user_job() {
  local label="$1"
  local plist="$2"
  local target="gui/$UID_NOW/$label"
  local output=""

  if launchctl print "$target" >/dev/null 2>&1; then
    echo "  $label already loaded; restarting it."
    launchctl kickstart -k "$target"
    return 0
  fi

  if output="$(launchctl bootstrap "gui/$UID_NOW" "$plist" 2>&1)"; then
    echo "  $label loaded."
    return 0
  fi

  echo "  First bootstrap of $label failed: $output"
  echo "  Clearing stale user launchd state and retrying..."

  launchctl bootout "$target" >/dev/null 2>&1 || true
  launchctl bootout "gui/$UID_NOW" "$plist" >/dev/null 2>&1 || true
  wait_until_unloaded "$target" || true
  sleep 0.3

  if output="$(launchctl bootstrap "gui/$UID_NOW" "$plist" 2>&1)"; then
    echo "  $label loaded after retry."
    return 0
  fi

  echo "  launchd rejected $label again: $output" >&2
  echo "  Installed plist:" >&2
  plutil -p "$plist" >&2 || true
  fail "Could not load $label. Run: launchctl print gui/$UID_NOW"
}

[[ "$(uname -s)" == "Darwin" ]] || fail "Deadlock supports macOS only."
[[ "$(uname -m)" == "arm64" ]] || fail "Deadlock currently supports Apple Silicon Macs."
[[ "$(id -u)" -ne 0 ]] || fail "Run ./install.sh as your normal user; it requests sudo only for privileged files."
command -v xcrun >/dev/null 2>&1 || fail "Install Apple's Command Line Tools first: xcode-select --install"
xcrun --find swift >/dev/null 2>&1 || fail "Swift was not found. Install Apple's Command Line Tools: xcode-select --install"

cd "$ROOT"

echo "== Deadlock v1.3.6 preview =="
echo "Building the current repository source..."
./build.sh

[[ -d "$ROOT/dist/deadlock.app" ]] || fail "Build did not produce dist/deadlock.app."
[[ -x "$ROOT/dist/bedtimelockd" ]] || fail "Build did not produce dist/bedtimelockd."

echo "Stopping the previous installation..."
launchctl bootout "gui/$UID_NOW/com.deadlock.menubar" >/dev/null 2>&1 || true
pkill -u "$UID_NOW" -f "/Applications/deadlock[.]app/Contents/MacOS/deadlock" >/dev/null 2>&1 || true
wait_until_unloaded "gui/$UID_NOW/com.deadlock.menubar" || true

sudo launchctl bootout system/com.deadlock.watchdog >/dev/null 2>&1 || true
wait_until_unloaded_root system/com.deadlock.watchdog || true
sudo launchctl bootout system/com.deadlock.daemon >/dev/null 2>&1 || true
wait_until_unloaded_root system/com.deadlock.daemon || true

echo "Installing app and privileged components..."
sudo mkdir -p   /Library/PrivilegedHelperTools   /Library/LaunchDaemons   "$SUPPORT"   "$RECOVERY"
mkdir -p "$HOME/Library/LaunchAgents"

sudo rm -rf /Applications/deadlock.app
sudo /usr/bin/ditto "$ROOT/dist/deadlock.app" /Applications/deadlock.app
sudo install -m 755 "$ROOT/dist/bedtimelockd" /Library/PrivilegedHelperTools/bedtimelockd

sudo install -m 644   "$ROOT/LaunchDaemons/com.deadlock.daemon.plist"   /Library/LaunchDaemons/com.deadlock.daemon.plist
sudo install -m 644   "$ROOT/LaunchDaemons/com.deadlock.watchdog.plist"   /Library/LaunchDaemons/com.deadlock.watchdog.plist
install -m 644   "$ROOT/LaunchAgents/com.deadlock.menubar.plist"   "$AGENT_PLIST"

# Keep last-known-good copies for the watchdog/recovery path without touching
# the signed policy/state files that may already exist in Application Support.
sudo install -m 755   "$ROOT/dist/bedtimelockd"   "$RECOVERY/bedtimelockd.backup"
sudo install -m 644   "$ROOT/LaunchDaemons/com.deadlock.daemon.plist"   "$SUPPORT/com.deadlock.daemon.plist"
sudo install -m 644   "$ROOT/LaunchDaemons/com.deadlock.watchdog.plist"   "$SUPPORT/com.deadlock.watchdog.plist"
sudo install -m 644   "$ROOT/LaunchDaemons/com.deadlock.daemon.plist"   "$RECOVERY/com.deadlock.daemon.plist"
sudo install -m 644   "$ROOT/LaunchDaemons/com.deadlock.watchdog.plist"   "$RECOVERY/com.deadlock.watchdog.plist"

sudo chown root:wheel /Library/PrivilegedHelperTools/bedtimelockd
sudo chown root:wheel   /Library/LaunchDaemons/com.deadlock.daemon.plist   /Library/LaunchDaemons/com.deadlock.watchdog.plist
sudo chown -R root:wheel "$SUPPORT" "$RECOVERY"
sudo chmod 700 "$SUPPORT" "$RECOVERY"

echo "Validating installed files..."
sudo plutil -lint /Library/LaunchDaemons/com.deadlock.daemon.plist >/dev/null
sudo plutil -lint /Library/LaunchDaemons/com.deadlock.watchdog.plist >/dev/null
plutil -lint "$AGENT_PLIST" >/dev/null
codesign --verify --deep --strict /Applications/deadlock.app
sudo codesign --verify --strict /Library/PrivilegedHelperTools/bedtimelockd

echo "Starting enforcement..."
sudo launchctl enable system/com.deadlock.daemon >/dev/null 2>&1 || true
sudo launchctl enable system/com.deadlock.watchdog >/dev/null 2>&1 || true
launchctl enable "gui/$UID_NOW/com.deadlock.menubar" >/dev/null 2>&1 || true

# Start the daemon first, then its watchdog, then the user-facing menu process.
# Each bootstrap identifies itself and retries once after clearing stale
# launchd state, avoiding opaque "Bootstrap failed: 5" installer failures.
bootstrap_system_job   com.deadlock.daemon   /Library/LaunchDaemons/com.deadlock.daemon.plist

bootstrap_system_job   com.deadlock.watchdog   /Library/LaunchDaemons/com.deadlock.watchdog.plist

bootstrap_user_job   com.deadlock.menubar   "$AGENT_PLIST"

sudo launchctl kickstart -k system/com.deadlock.daemon
sudo launchctl kickstart -k system/com.deadlock.watchdog
launchctl kickstart "gui/$UID_NOW/com.deadlock.menubar" >/dev/null 2>&1 || true

sleep 1

sudo launchctl print system/com.deadlock.daemon >/dev/null   || fail "The privileged daemon did not remain loaded."
sudo launchctl print system/com.deadlock.watchdog >/dev/null   || fail "The watchdog did not remain loaded."
launchctl print "gui/$UID_NOW/com.deadlock.menubar" >/dev/null   || fail "The menu-bar helper did not remain loaded."

MENU_COUNT="$(
  pgrep -u "$UID_NOW" -f "/Applications/deadlock[.]app/Contents/MacOS/deadlock" 2>/dev/null     | wc -l     | tr -d ' '
)"

if [[ "$MENU_COUNT" -gt 1 ]]; then
  echo "Collapsing $MENU_COUNT stale menu processes to one..."
  "$ROOT/deadlockctl" menu
fi

echo
echo "Deadlock v1.3.6 installed from the current source tree."
echo "Exactly one menu-bar process is enforced."
echo "IINA is not automated or DNS-blocked."
echo "Diagnostics: bash $ROOT/deadlockctl doctor"
