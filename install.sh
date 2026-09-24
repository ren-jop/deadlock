#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
ARCHIVE="$ROOT/source/deadlock-v1.2.2.zip"

fail() { echo "error: $*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || fail "Deadlock supports macOS only."
[[ "$(uname -m)" == "arm64" ]] || fail "Deadlock currently supports Apple Silicon Macs."
command -v xcrun >/dev/null 2>&1 || fail "Install Apple's Command Line Tools first: xcode-select --install"
xcrun --find swift >/dev/null 2>&1 || fail "Swift was not found. Install Apple's Command Line Tools: xcode-select --install"
[[ -f "$ARCHIVE" ]] || fail "Bundled source archive is missing: $ARCHIVE"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/deadlock-install.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

echo "== Deadlock v1.2.2 =="
echo "Preparing source..."
ditto -x -k "$ARCHIVE" "$WORK"
SRC="$WORK/deadlock"
[[ -f "$SRC/Package.swift" ]] || fail "Source archive is invalid."

chmod +x "$SRC/build.sh" "$SRC/install.sh"
cd "$SRC"

echo "Building release..."
./build.sh

echo "Installing..."
./install.sh

echo
echo "Deadlock is installed at /Applications/deadlock.app"
echo "Open the menu-bar app to configure schedules and blocking."
