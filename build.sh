#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

[[ "$(uname -s)" == "Darwin" ]] || { echo "build.sh must run on macOS." >&2; exit 1; }

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)"

rm -rf dist
mkdir -p dist/deadlock.app/Contents/MacOS dist/deadlock.app/Contents/Resources
cp "$BIN/BedtimeLock" dist/deadlock.app/Contents/MacOS/deadlock
cp Info.plist dist/deadlock.app/Contents/Info.plist
cp Resources/deadlock-menubar.png dist/deadlock.app/Contents/Resources/deadlock-menubar.png
cp "$BIN/bedtimelockd" dist/bedtimelockd

/usr/bin/codesign --force --deep --sign - dist/deadlock.app
/usr/bin/codesign --force --sign - dist/bedtimelockd

plutil -lint dist/deadlock.app/Contents/Info.plist
plutil -lint LaunchDaemons/com.deadlock.daemon.plist
plutil -lint LaunchDaemons/com.deadlock.watchdog.plist
plutil -lint LaunchAgents/com.deadlock.menubar.plist

codesign --verify --deep --strict dist/deadlock.app
codesign --verify --strict dist/bedtimelockd

echo "Built:"
echo "  $PWD/dist/deadlock.app"
echo "  $PWD/dist/bedtimelockd"
