# Deadlock

A small macOS app for enforcing sleep hours and blocking distracting websites.

**Status:** v1.3.6 preview  
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

### Bed Guard (AirPods)

Bed Guard is an optional second sleep trigger for keeping the laptop out of bed.

1. Connect and wear AirPods or other Apple headphones that expose head-tracking motion.
2. Open Deadlock and choose **Record current bed posture (5 sec)** while lying/reclining in the position you normally use the laptop.
3. Record up to four positions (for example back, left side and right side).
4. Enable **Bed Guard**.

Deadlock compares the live AirPods gravity vector with those local calibration samples. A matching posture has to remain stable for 20 seconds before the menu app asks the root daemon to use the same `pmset sleepnow` mechanism as the normal sleep lock. If you wake the Mac while staying in the matched posture, the detector can trigger again.

The raw motion stream is not written to disk or sent anywhere. Only the small calibrated gravity vectors are saved. Bed Guard does not use the microphone or camera.

This is deliberately posture detection rather than pretending AirPods know where the bed is. Sitting perfectly upright on the bed can look like sitting upright at a desk, so for that case a future optional BLE/pressure sensor can be fused with the AirPods signal. For normal reclined laptop-in-bed use, calibration gives Deadlock a distinct signal without adding a camera.

### Emergency sleep access

If the sleep lock is already enforcing and you genuinely need the Mac immediately, open Deadlock and use **Emergency access now…**. It suspends only sleep enforcement for up to two hours, does not edit the saved schedule, leaves the Porn Blocker and distraction blocking alone, and automatically restores sleep enforcement when it expires.

Emergency overrides are not limited by a per-sleep-window usage counter. The normal deliberate emergency path can be used again in later or repeated lock windows, but every activation still requires a strong concrete reason and the confirmation phrase. Active override state is persisted so daemon restarts do not cancel it.

The legacy instant emergency IPC path remains for compatibility with the temporary one-night exception, but the per-window consumption counter has been removed. If the menu UI is inconvenient, the installed CLI path is:

```bash
./deadlockctl emergency-now
```

The deliberate emergency override remains the normal path: it requires at least 80 characters and 12 words describing the concrete consequence, followed by the `EMERGENCY UNLOCK` confirmation phrase, with no timed wait.

### YouTube

YouTube is handled differently from other blocked domains.

When `youtube.com` is in the distraction list:

- Google Chrome receives a mandatory macOS `URLBlocklist`.
- Helium receives the same Chromium-native `URLBlocklist` under its `net.imput.helium` managed-preferences domain.
- Firefox receives Mozilla's native macOS `WebsiteFilter` policy with YouTube match patterns.
- Safari uses a user-session guard: Apple Events first, then an Accessibility fallback that closes only the active YouTube tab.
- Opera GX, Opera, Brave, Edge, Vivaldi, Arc, Dia, Chromium, Chrome variants, Sidekick, Yandex, SigmaOS and similar Chromium browsers use Chromium scripting when available, then Accessibility if needed.
- Zen, Firefox Developer Edition/Nightly, LibreWolf, Waterfox, Floorp, DuckDuckGo, Orion, Min and other recognized browsers use the generic Accessibility path.
- Unknown future browsers whose app identity clearly identifies them as a browser also get the Accessibility fallback.
- IINA is always excluded from browser enforcement.
- The official YouTube app / installed YouTube web apps are blocked.
- YouTube is **not** written into Deadlock's DNS / `/etc/hosts` block.
- IINA is explicitly left alone.

This keeps normal YouTube DNS resolution available for IINA-based playback while browsers refuse website navigation. Chrome exposes the applied rule at `chrome://policy`; Helium at `helium://policy`; Firefox at `about:policies`. Browsers that do not expose a usable native policy or AppleScript tab API use one-time macOS Accessibility permission instead.

## Browser compatibility

Deadlock no longer relies on one hard-coded browser path. The logged-in helper uses a browser catalog plus a generic Accessibility fallback.

Explicitly recognized families include Safari / Safari Technology Preview, Chrome and Chrome variants, Chromium, Brave, Edge variants, Arc, Dia, Vivaldi, Opera, Opera GX, Helium, Firefox and Firefox variants, Zen, LibreWolf, Waterfox, Floorp, DuckDuckGo, Orion, Sidekick, Yandex Browser, SigmaOS, Thorium, Wavebox, Ghost Browser and Min.

For browser forks that do not expose a compatible scripting API, Deadlock checks the active window title and accessible address-bar controls for YouTube, then sends Command-W only to the frontmost browser tab. This keeps the network path available to IINA.

### Browser compatibility

Deadlock's browser-only YouTube exception is designed around browser families rather than a tiny fixed list.

Known coverage includes:

- Safari and Safari Technology Preview
- Google Chrome family, Chromium, Brave, Edge, Vivaldi
- Opera and Opera GX
- Arc and Dia
- Helium, Sidekick, Yandex Browser, SigmaOS
- Firefox family, including Developer Edition and Nightly
- Zen, LibreWolf, Waterfox, Floorp
- DuckDuckGo Browser, Orion and Min
- Tor Browser and Mullvad Browser
- Wavebox and Ghost Browser by browser identity
- Other macOS apps whose bundle/name clearly identifies them as a browser use the generic Accessibility fallback

Native browser policy is preferred when supported. Otherwise Deadlock uses AppleScript where available, then macOS Accessibility to inspect the active window/address field and issue Command-W only when the active tab is YouTube. IINA is explicitly excluded.

Because third-party browsers can change their macOS identifiers or Accessibility trees between releases, no app can truthfully guarantee every browser forever; the generic fallback is there so most new forks continue working without a Deadlock update.

## Distraction presets

The Distractions panel includes grouped quick presets for common distracting sites:

- Social & feeds
- Video & streaming
- Forums & communities
- Messaging
- Gaming
- Shopping
- News & headlines

Each site can be toggled individually, each group has Add all / Remove all, and custom domains can still be mixed into the same block list. Presets do not create a second rules system; they edit the normal Deadlock distraction-domain list.

Discord is intentionally treated as an always-allowed productivity service. Existing saved Discord blocks are removed automatically when the daemon starts, and attempts to add `discord.com` or its subdomains to the distraction list are ignored.

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

## Resilient launchd installation

Deadlock v1.3.6 replaces the accumulated installer patches with one clean idempotent install flow. Each launchd job is unloaded, verified, bootstrapped by name, and retried once after stale launchd state is cleared. If macOS still rejects a job, the installer prints the exact label, launchd error, plist and signature diagnostics instead of stopping at an unhelpful `Bootstrap failed: 5`.

## Single menu-bar instance

Deadlock v1.3.5 guards the menu UI with a per-user process lock. Opening the app manually while the LaunchAgent copy is already running now exits the duplicate before it can create a second menu-bar icon.

The LaunchAgent only restarts the menu process after an abnormal exit, so a clean duplicate exit cannot turn into a five-second relaunch loop. The installer and `deadlockctl menu` also clear stray UI processes left behind by older builds before launching one canonical instance.

## Permissions across local rebuilds

Deadlock is intentionally buildable without a paid Apple developer account. Older builds were ad-hoc signed with the default changing cdhash identity, so macOS could keep an approved Deadlock entry in Privacy & Security while still treating the newly rebuilt binary as a different requester.

Starting with **v1.3.4**, the app and privileged helper are still locally/ad-hoc signed, but each carries a stable designated code requirement. When upgrading from an older build, macOS may ask once more for Accessibility or Automation approval because the identity format is changing. Subsequent local rebuilds keep the same designated requirement, so that approval should no longer be invalidated simply because the executable bytes changed.

You can inspect the installed identity with:

```bash
codesign -d -r- /Applications/deadlock.app 2>&1
```

The expected designated requirement contains `local.deadlock.BedtimeLock`.

## App identity

The app icon is an original **midnight guardian** mark generated during the local build: a dark lock, crescent moon and restrained guardian-eye motif. It is intentionally anime-adjacent rather than copied from an existing anime character or franchise, so the repository can be shared without artwork licensing problems.

## Diagnostics

```bash
bash ./deadlockctl status
bash ./deadlockctl web
bash ./deadlockctl doctor
```

`deadlockctl web` shows the active policy, configured domains, Deadlock-owned hosts entries and resolver checks.

A publicly resolving `youtube.com` is expected in v1.3.6 because YouTube remains outside DNS blocking so IINA continues to work.

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

