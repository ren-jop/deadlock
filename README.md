# deadlock

A native macOS enforcement tool for sleep schedules and distraction rules. The menu-bar app is a controller; a privileged daemon owns enforcement.

**Current installable build:** v1.2.3 preview  
**Platform:** Apple Silicon macOS 14+  
**Stack:** Swift, SwiftPM, launchd, IOKit, Unix IPC

> Deadlock installs privileged components and a watchdog. Review the installer and uninstall flow before installing.

## Install

```bash
git clone --depth 1 https://github.com/ren-jop/deadlock.git
cd deadlock
bash ./install.sh
```

The installer validates the vendored source snapshot, applies the reviewed patch set under `source/patches/`, builds locally, then installs the app, daemon and watchdog. This is the same source path validated by GitHub Actions on macOS ARM64.

## Development maintenance session

To temporarily bypass Deadlock's own settings-edit locks while debugging:

```bash
bash ./maintenance-unlock.sh
```

The bypass is memory-only. Restarting `bedtimelockd` or rebooting restores the saved settings restrictions.

## Website blocking diagnostics

```bash
bash ./deadlockctl web
```

v1.2.3 adds corrected IPv6 sink entries, mobile hostname variants, immediate rescanning when a block starts, and a browser-scoped Accessibility fallback for already-open browser sessions.

## Update

```bash
git pull --ff-only
bash ./install.sh
```

## Uninstall

```bash
bash ./uninstall.sh
```

The normal uninstall policy remains intentionally high-friction.

## Architecture

```text
menu-bar app
     │ Unix IPC
     ▼
root daemon ── schedule / policy / sleep enforcement
     │
     ├─ managed web blocking
     └─ watchdog / recovery
```

## Verification

GitHub Actions reconstructs the same vendored source, applies the same patches, validates shell scripts and runs a release Swift build on macOS ARM64.

Runtime website blocking still depends on the target Mac's Accessibility permission, browser connection state and DNS caching, so `deadlockctl web` is included for diagnosis.

## Project links

- Project page: https://ren-jop.github.io/deadlock/
- Portfolio: https://ren-jop.github.io/
- Author: Ren Jopson

## License

No open-source license has been selected yet. The repository is public for source visibility and review; copyright remains with the author unless a license is added later.
