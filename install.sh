#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
PREFIX="$ROOT/source/deadlock-v1.2.2.zip.b64.part-"
PATCH_DIR="$ROOT/source/patches"

fail() { echo "error: $*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || fail "Deadlock supports macOS only."
[[ "$(uname -m)" == "arm64" ]] || fail "Deadlock currently supports Apple Silicon Macs."
command -v xcrun >/dev/null 2>&1 || fail "Install Apple's Command Line Tools first: xcode-select --install"
xcrun --find swift >/dev/null 2>&1 || fail "Swift was not found. Install Apple's Command Line Tools: xcode-select --install"
command -v patch >/dev/null 2>&1 || fail "The system patch utility is required."

WORK="$(mktemp -d "${TMPDIR:-/tmp}/deadlock-install.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

shopt -s nullglob
PARTS=("${PREFIX}"*)
PATCHES=("$PATCH_DIR"/*.patch)
(( ${#PARTS[@]} > 0 )) || fail "Bundled source snapshot is missing."
(( ${#PATCHES[@]} > 0 )) || fail "v1.2.3 patch set is missing."

echo "== Deadlock v1.2.3 preview =="
echo "Validating bundled source..."
cat "${PARTS[@]}" > "$WORK/deadlock.zip.b64"
/usr/bin/base64 -D < "$WORK/deadlock.zip.b64" > "$WORK/deadlock.zip"
/usr/bin/unzip -tq "$WORK/deadlock.zip" >/dev/null || fail "Bundled source snapshot failed its integrity check."
/usr/bin/ditto -x -k "$WORK/deadlock.zip" "$WORK"

SRC="$WORK/deadlock"
[[ -f "$SRC/Package.swift" ]] || fail "Bundled source snapshot is invalid."

echo "Applying v1.2.3 web-blocking and maintenance fixes..."
for patch_file in "${PATCHES[@]}"; do
  /usr/bin/patch --batch --forward -p1 -d "$SRC" < "$patch_file" >/dev/null || fail "Could not apply $(basename "$patch_file")."
done

chmod +x "$SRC/build.sh" "$SRC/install.sh" "$SRC/deadlockctl" "$SRC/maintenance-unlock.sh"

echo "Building and installing..."
cd "$SRC"
./install.sh

echo
echo "Deadlock v1.2.3 is installed at /Applications/deadlock.app"
echo "For this debugging session, run: ./maintenance-unlock.sh"
echo "Website diagnostics: ./deadlockctl web"
