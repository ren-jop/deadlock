#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
ARCHIVE="$ROOT/source/deadlock-v1.2.2.zip"

[[ "$(uname -s)" == "Darwin" ]] || { echo "error: macOS only." >&2; exit 1; }
[[ -f "$ARCHIVE" ]] || { echo "error: bundled source archive is missing." >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/deadlock-uninstall.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
ditto -x -k "$ARCHIVE" "$WORK"
chmod +x "$WORK/deadlock/uninstall.sh"
exec "$WORK/deadlock/uninstall.sh"
