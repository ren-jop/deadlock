#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
PREFIX="$ROOT/source/deadlock-v1.2.2.zip.b64.part-"

fail() { echo "error: $*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || fail "Deadlock supports macOS only."
[[ "$(uname -m)" == "arm64" ]] || fail "Deadlock currently supports Apple Silicon Macs."
command -v xcrun >/dev/null 2>&1 || fail "Install Apple's Command Line Tools first: xcode-select --install"
xcrun --find swift >/dev/null 2>&1 || fail "Swift was not found. Install Apple's Command Line Tools: xcode-select --install"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/deadlock-install.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

shopt -s nullglob
PARTS=("${PREFIX}"*)
(( ${#PARTS[@]} > 0 )) || fail "Bundled source snapshot is missing."

echo "== Deadlock v1.2.2 preview =="
echo "Validating source snapshot..."
cat "${PARTS[@]}" > "$WORK/deadlock.zip.b64"
/usr/bin/base64 -D < "$WORK/deadlock.zip.b64" > "$WORK/deadlock.zip"
/usr/bin/unzip -tq "$WORK/deadlock.zip" >/dev/null || fail "Bundled source snapshot failed its integrity check."
/usr/bin/ditto -x -k "$WORK/deadlock.zip" "$WORK"

SRC="$WORK/deadlock"
[[ -f "$SRC/Package.swift" ]] || fail "Bundled source snapshot is invalid."
chmod +x "$SRC/build.sh" "$SRC/install.sh"

echo "Building release..."
cd "$SRC"
./build.sh

echo "Installing privileged components..."
./install.sh

echo
echo "Deadlock is installed at /Applications/deadlock.app"
echo "Open the menu-bar app to configure schedules and blocking."
