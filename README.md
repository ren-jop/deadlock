# Deadlock

Native macOS sleep-enforcement and distraction-control software.

Deadlock separates its menu-bar UI from a privileged, event-driven daemon so configured sleep windows and blocking policy do not depend on the GUI remaining open.

> **Preview software.** Deadlock installs privileged launchd services and is intentionally high-friction. Review the source and uninstall behaviour before installing.

## Install

Requirements: **Apple Silicon Mac**, macOS 14+, and Apple's Command Line Tools.

```bash
git clone https://github.com/ren-jop/deadlock.git
cd deadlock
./install.sh
```

The installer validates the bundled v1.2.2 source snapshot, builds a release with Swift Package Manager, installs the app and privileged daemon, and starts the launchd services. It asks for `sudo` only when system-level components are installed.

To remove Deadlock:

```bash
./uninstall.sh
```

Deadlock's daemon intentionally enforces the project's uninstall-delay policy; the root wrapper uses the same verified source snapshot as installation.

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
- ad-hoc signing for local preview builds
- event-driven design intended to keep idle overhead low

## Reproducible source snapshot

The currently validated **v1.2.2** snapshot is vendored under `source/` as ordered base64 chunks. `install.sh` concatenates them, decodes the ZIP, runs an integrity check, and only then builds it in a temporary directory.

This avoids depending on an external download while the project is still in preview. A notarized binary distribution is not provided yet.

## Related projects

- [Focus](https://github.com/ren-jop/focus) — focus timer and session history
- [Planner](https://github.com/ren-jop/planner) — Apple Calendar planning layer
- [Project page](https://ren-jop.github.io/deadlock/)

## Status

Current documented build: **v1.2.2 preview**.

## License

No open-source license has been selected. The repository is public for source visibility and release distribution; copyright remains with the author unless a license is added later.
