# deadlock

A native macOS enforcement tool for sleep schedules and distraction rules. The architecture separates a lightweight menu-bar controller from a privileged root daemon so enforcement does not depend on the GUI staying open.

**Current build:** v1.2.2 preview  
**Platform:** Apple Silicon macOS 14+  
**Stack:** Swift, SwiftPM, launchd, IOKit, Unix IPC

> **Read this before installing.** deadlock installs a root daemon and a watchdog designed to restore enforcement components. Uninstalling is intentionally delayed by a 24-hour cooldown. Review `install.sh`, `scripts/install-system.sh`, and `uninstall.sh` first.

## Install

```bash
git clone --depth 1 https://github.com/ren-jop/deadlock.git
cd deadlock
./install.sh
```

The installer builds locally, explains the privileged components, asks for `sudo` only when installing them, validates the launchd configuration, and starts the daemon, watchdog, and menu app.

## What installation changes

- `/Applications/deadlock.app`
- `/Library/PrivilegedHelperTools/bedtimelockd`
- two system LaunchDaemons
- `~/Library/LaunchAgents/com.deadlock.menubar.plist`
- protected state and recovery data under `/var/db/deadlock` and `/Library/Application Support/deadlock`

## Update

```bash
git pull --ff-only
./install.sh
```

## Uninstall

```bash
./uninstall.sh
```

The first request starts or confirms the **24-hour uninstall cooldown**. Run the command again after the daemon reports that the cooldown is complete.

## Architecture

```text
menu-bar app
     │ Unix IPC
     ▼
root daemon ── schedule / policy / sleep enforcement
     │
     └──────── watchdog / recovery
```

The working sleep path uses IOKit wake handling plus `pmset sleepnow`. Distraction and adult-content safeguards are separate policies, and Focus can activate distraction protection over local IPC.

## Development

```bash
swift build -c release
./build.sh
./deadlock-smoke.sh
```

CI compiles the Swift package on macOS for each push and pull request.

## Security model

deadlock is intentionally high-friction software. Privileged pieces, launchd configuration, watchdog behavior, install paths, and the uninstall flow are kept visible in this repository so they can be reviewed before installation.

## Project links

- Project page: https://ren-jop.github.io/deadlock/
- Portfolio: https://ren-jop.github.io/
- Author: Ren Jopson

## License

No open-source license has been selected yet. The repository is public for source visibility and review; copyright remains with the author unless a license is added later.
