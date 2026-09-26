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

ICONSET="$PWD/dist/deadlock.iconset"
xcrun swift Scripts/make_icon.swift "$ICONSET"
/usr/bin/iconutil -c icns "$ICONSET" -o dist/deadlock.app/Contents/Resources/deadlock.icns
rm -rf "$ICONSET"

# Ad-hoc signatures normally fall back to a changing cdhash identity, which
# causes TCC (Accessibility/Automation) to treat each local rebuild as a new
# app. Give both binaries a stable designated requirement instead. This keeps
# the project free of paid certificates while letting future rebuilds match the
# same local code requirement.
APP_REQUIREMENT='=designated => identifier "local.deadlock.BedtimeLock"'
DAEMON_REQUIREMENT='=designated => identifier "local.deadlock.bedtimelockd"'

/usr/bin/codesign \
  --force \
  --deep \
  --sign - \
  --identifier "local.deadlock.BedtimeLock" \
  --requirements "$APP_REQUIREMENT" \
  dist/deadlock.app

/usr/bin/codesign \
  --force \
  --sign - \
  --identifier "local.deadlock.bedtimelockd" \
  --requirements "$DAEMON_REQUIREMENT" \
  dist/bedtimelockd

plutil -lint dist/deadlock.app/Contents/Info.plist
plutil -lint LaunchDaemons/com.deadlock.daemon.plist
plutil -lint LaunchDaemons/com.deadlock.watchdog.plist
plutil -lint LaunchAgents/com.deadlock.menubar.plist

codesign --verify --deep --strict dist/deadlock.app
codesign --verify --strict dist/bedtimelockd

APP_REQUIREMENT_OUTPUT="$(
  /usr/bin/codesign -d -r- dist/deadlock.app 2>&1 || true
)"
DAEMON_REQUIREMENT_OUTPUT="$(
  /usr/bin/codesign -d -r- dist/bedtimelockd 2>&1 || true
)"

grep -F 'designated => identifier "local.deadlock.BedtimeLock"' <<<"$APP_REQUIREMENT_OUTPUT" >/dev/null \
  || { echo "deadlock.app is missing its stable designated requirement." >&2; exit 1; }

grep -F 'designated => identifier "local.deadlock.bedtimelockd"' <<<"$DAEMON_REQUIREMENT_OUTPUT" >/dev/null \
  || { echo "bedtimelockd is missing its stable designated requirement." >&2; exit 1; }

[[ -f dist/deadlock.app/Contents/Resources/deadlock.icns ]] \
  || { echo "deadlock.icns was not generated." >&2; exit 1; }

echo "Built:"
echo "  $PWD/dist/deadlock.app"
echo "  $PWD/dist/bedtimelockd"
