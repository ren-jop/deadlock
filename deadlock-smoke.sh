#!/bin/bash
set -u
fail=0
UID_NOW="$(id -u)"
pass(){ echo "PASS  $1"; }
bad(){ echo "FAIL  $1"; fail=$((fail+1)); }

[[ -x /Library/PrivilegedHelperTools/bedtimelockd ]] && pass "daemon binary" || bad "daemon binary"
sudo launchctl print system/com.deadlock.daemon >/dev/null 2>&1 && pass "daemon loaded" || bad "daemon loaded"
sudo launchctl print system/com.deadlock.watchdog >/dev/null 2>&1 && pass "watchdog loaded" || bad "watchdog loaded"
[[ -S /var/run/deadlock.sock ]] && pass "IPC socket" || bad "IPC socket"
[[ -d /Applications/deadlock.app ]] && pass "app bundle renamed to deadlock" || bad "deadlock.app missing"
[[ ! -d /Applications/BedtimeLock.app ]] && pass "old app bundle removed" || bad "old BedtimeLock.app still present"
[[ -f "$HOME/Library/LaunchAgents/com.deadlock.menubar.plist" ]] && pass "login item installed" || bad "login item installed"
launchctl print "gui/$UID_NOW/com.deadlock.menubar" >/dev/null 2>&1 && pass "menu LaunchAgent loaded" || bad "menu LaunchAgent loaded"
pgrep -f '/Applications/deadlock.app/Contents/MacOS/deadlock' >/dev/null 2>&1 && pass "menu process running" || bad "menu process running"

defaults read /Applications/deadlock.app/Contents/Info LSUIElement 2>/dev/null | grep -qiE '1|true' && pass "Dock-less menu app" || bad "Dock-less menu app"
grep -R 'pmset.*sleepnow' Sources/bedtimelockd >/dev/null 2>&1 && pass "sleep mechanism unchanged" || bad "sleep mechanism changed/missing"

if grep -RqiE 'pomotroid|127\.0\.0\.1:1314|roundChange' Sources 2>/dev/null; then
  bad "removed reward integration remains in executable source"
else
  pass "removed reward integration absent from executable source"
fi

if /Applications/deadlock.app/Contents/MacOS/deadlock --ipc status >/dev/null 2>&1; then
  pass "deadlock CLI/Focus bridge can reach daemon"
else
  bad "deadlock CLI/Focus bridge cannot reach daemon"
fi

PID="$(pgrep -x bedtimelockd | head -1 || true)"
if [[ -n "$PID" ]]; then
  CPU="$(ps -p "$PID" -o %cpu= | xargs)"
  RSS="$(ps -p "$PID" -o rss= | xargs)"
  echo "INFO  daemon pid=$PID cpu=${CPU}% rss=${RSS}KiB"
else
  bad "daemon process"
fi

exit "$fail"
