# Deadlock

Native macOS sleep-enforcement and distraction-control software.

Deadlock separates its menu-bar UI from a privileged, event-driven daemon so configured sleep windows and blocking policy do not depend on the GUI remaining open.

> **Preview software.** Deadlock installs privileged launchd services and is intentionally high-friction. Read the source and uninstall behaviour before installing.

## Install

**Requirements:** Apple Silicon Mac, macOS 14+, and Apple's Command Line Tools.

```bash
git clone https://github.com/ren-jop/deadlock.git
cd deadlock
./install.sh
```

The installer checks the environment, builds a release with Swift Package Manager, installs the app and privileged daemon, and starts the launchd services. It asks for `sudo` only when system-level components are installed.

To remove Deadlock:

```bash
./uninstall.sh
```

Deadlock enforces a 24-hour uninstall cooldown through the running daemon.

## Architecture

```text
menu-bar app
     │ local Unix IPC
     ▼
root daemon ── schedule / policy engine
     │
     ├─ sleep enforcement
     ├─ distraction blocking
     └─ web protection

Focus ───────────────► daemon IPC
```

## Engineering notes

- Swift + Swift Package Manager; no Xcode project or third-party dependencies
- privileged root daemon plus independent watchdog
- IOKit wake handling and `pmset sleepnow` for sleep enforcement
- local Unix-socket IPC between UI, Focus and daemon
- launchd-managed menu app, daemon and watchdog
- ad-hoc code signing for local builds
- event-driven design to avoid unnecessary idle polling

## Repository layout

The currently validated **v1.2.2** source snapshot is stored in `source/deadlock-v1.2.2.zip`. The root installer extracts that snapshot to a temporary directory, builds it, then discards the build workspace.

This keeps the public installation path reproducible while the project is still in preview. A notarized binary distribution is not provided yet.

## Related projects

- [Focus](https://github.com/ren-jop/focus) — focus timer and session history
- [Planner](https://github.com/ren-jop/planner) — Apple Calendar planning layer
- [Project page](https://ren-jop.github.io/deadlock/)

## Status

Current documented build: **v1.2.2 preview**.

## License

No open-source license has been selected. The repository is public for source visibility and release distribution; copyright remains with the author unless a license is added later.
