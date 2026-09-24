#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

[[ "$(uname -s)" == "Darwin" ]] || { echo "deadlock installs only on macOS." >&2; exit 1; }
[[ "$(id -u)" -ne 0 ]] || { echo "Run ./install.sh as your normal user; it will request sudo when needed." >&2; exit 1; }
command -v swift >/dev/null 2>&1 || {
  echo "Swift was not found." >&2
  echo "Install Apple's Command Line Tools with: xcode-select --install" >&2
  exit 1
}

cat <<'NOTICE'
deadlock installs privileged enforcement components:
  • /Applications/deadlock.app
  • a root daemon in /Library/PrivilegedHelperTools
  • two system LaunchDaemons, including a watchdog
  • a user LaunchAgent for the menu-bar app

The watchdog intentionally restores enforcement files.
Uninstalling intentionally uses a 24-hour cooldown.
Review scripts/install-system.sh and uninstall.sh before continuing.
NOTICE
echo

./build.sh
./scripts/install-system.sh
