# Deadlock

A small macOS app for enforcing sleep hours and blocking distracting websites.

**Status:** v1.2.8 preview  
**Platform:** Apple Silicon, macOS 14+  
**Stack:** Swift, SwiftPM, launchd, IOKit, Unix sockets

## Why

I wanted blocking rules that would keep working even if I closed the menu-bar app. The interface edits settings and shows status; enforcement lives in a privileged daemon.

## Install

```bash
git clone --depth 1 https://github.com/ren-jop/deadlock.git
cd deadlock
bash ./install.sh
```

The installer builds locally, installs the app and privileged components, and configures launchd.

## What it does

- Enforces configured sleep windows.
- Blocks configured distraction domains.
- Keeps distraction domains blocked continuously when the weekly schedule is off.
- Supports scheduled and manual distraction windows.
- Keeps enforcement separate from the menu-bar process.
- Provides a watchdog and recovery path.
- Exposes status and web diagnostics through `deadlockctl`.

### YouTube

YouTube is handled differently from other blocked domains.

When `youtube.com` is in the distraction list:

- Google Chrome receives a mandatory macOS `URLBlocklist`.
- Firefox receives Mozilla's native macOS `WebsiteFilter` policy with YouTube match patterns.
- Chrome and Firefox reject those sites themselves, so their YouTube block does not depend on Accessibility or Automation permission.
- The logged-in helper remains as a fallback for other supported browsers.
- The official YouTube app / installed YouTube web apps are blocked.
- YouTube is **not** written into Deadlock's DNS / `/etc/hosts` block.
- IINA is explicitly left alone.

This keeps normal YouTube DNS resolution available for IINA-based playback while browsers refuse website navigation. Chrome exposes the applied rule at `chrome://policy` under `URLBlocklist`; Firefox exposes it at `about:policies` under `WebsiteFilter`.

## How it works

```text
menu-bar app
     │
     │ Unix socket
     ▼
root daemon
     ├─ sleep enforcement
     ├─ distraction policy
     ├─ browser/app monitoring
     └─ managed hosts entries
```

## Diagnostics

```bash
bash ./deadlockctl status
bash ./deadlockctl web
bash ./deadlockctl doctor
```

`deadlockctl web` shows the active policy, configured domains, Deadlock-owned hosts entries and resolver checks.

A publicly resolving `youtube.com` is expected in v1.2.8 because Chrome and Firefox use browser policy rather than DNS for YouTube.

## Update

```bash
git pull --ff-only
bash ./install.sh
```

## Uninstall

```bash
bash ./uninstall.sh
```

The normal uninstall path is intentionally high-friction.

## Development

The top-level `Sources/` tree is the canonical installable source. `install.sh` builds that exact tree locally before replacing the app, daemon and launchd jobs.

The older vendored snapshot and `source/patches/` directory are retained as historical migration material only. GitHub Actions now builds the same top-level source that the installer uses.

## License

No open-source license has been selected yet.
