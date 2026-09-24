#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
PREFIX="$ROOT/source/deadlock-v1.2.2.zip.b64.part-"

fail() { echo "error: $*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || fail "Deadlock supports macOS only."

WORK="$(mktemp -d "${TMPDIR:-/tmp}/deadlock-uninstall.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

shopt -s nullglob
PARTS=("${PREFIX}"*)
(( ${#PARTS[@]} > 0 )) || fail "Bundled source snapshot is missing."

cat "${PARTS[@]}" > "$WORK/deadlock.zip.b64"
/usr/bin/base64 -D < "$WORK/deadlock.zip.b64" > "$WORK/deadlock.zip"
/usr/bin/unzip -tq "$WORK/deadlock.zip" >/dev/null || fail "Bundled source snapshot failed its integrity check."
/usr/bin/ditto -x -k "$WORK/deadlock.zip" "$WORK"

chmod +x "$WORK/deadlock/uninstall.sh"
exec "$WORK/deadlock/uninstall.sh"
