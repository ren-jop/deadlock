# Deadlock

Native macOS sleep-enforcement and distraction-control software.

Deadlock separates its menu-bar UI from a privileged, event-driven daemon so sleep windows and blocking policy do not depend on the GUI staying open.

> **v1.2.3 preview.** Deadlock installs privileged `launchd` services and is intentionally high-friction. Review the source patch set and uninstall behaviour before installing.

## Install

Requirements: **Apple Silicon**, macOS 14+, and Apple's Command Line Tools.

```bash
git clone https://github.com/ren-jop/deadlock.git
cd deadlock
./install.sh
```

That is the complete install path. The bootstrapper validates the bundled source, applies the readable v1.2.3 patch set, builds with Swift Package Manager, and installs the menu app, root daemon and watchdog. It requests `sudo` only for system-level installation.

To uninstall:

```bash
./uninstall.sh
```

## Development maintenance session

While debugging, bypass Deadlock's own settings-edit locks without deleting the saved policy:

```bash
./maintenance-unlock.sh
```

The bypass exists **only in the running daemon's memory**. Restarting `bedtimelockd` or rebooting restores the normal Settings Guard, weekday edit restrictions, active-window restrictions and delayed-loosening behaviour.

## Website blocking

v1.2.3 strengthens distraction blocking in two layers:

1. managed `/etc/hosts` entries cover the base, `www`, `m` and `mobile` host variants on IPv4 and IPv6;
2. a browser-scoped Accessibility fallback rescans when protection starts, catching an already-open tab or connection that survives a DNS change.

Run:

```bash
./deadlockctl web
```

to inspect Deadlock's hosts sections and resolver results. If the Accessibility fallback is needed, macOS must grant Accessibility access to the installed Deadlock component.

## Architecture

```text
menu-bar app
     │ local Unix IPC
     ▼
root daemon ── schedule / policy engine
     │
     ├─ sleep enforcement
     ├─ distraction policy ──► /etc/hosts
     │                         + browser fallback
     └─ adult-content / SafeSearch policy

Focus ───────────────────────► daemon IPC
```

## Engineering notes

- Swift + Swift Package Manager; no Xcode project or third-party dependencies
- privileged root daemon plus independent watchdog
- IOKit wake handling and `pmset sleepnow`
- local Unix-socket IPC between UI, Focus and daemon
- `launchd`-managed menu app, daemon and watchdog
- event-driven design intended to keep idle overhead low
- ad-hoc signing for local preview builds

## Reproducible preview source

The validated v1.2.2 source snapshot is vendored under `source/` as ordered base64 chunks. The v1.2.3 changes are readable under `source/patches/`; `install.sh` reconstructs the snapshot and applies the patch set before compiling.

This avoids an external download dependency while the project is still a local preview. A notarized binary distribution is not provided yet.

## Related

- [Project page](https://ren-jop.github.io/deadlock/)
- [Focus](https://github.com/ren-jop/focus)
- [Planner](https://github.com/ren-jop/planner)

## License

No open-source license has been selected. The repository is public for source visibility and release distribution; copyright remains with the author unless a license is added later.
