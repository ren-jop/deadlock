# Deadlock

A small macOS app for enforcing sleep hours and blocking distracting websites.

**Status:** v1.3.4 preview  
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

A publicly resolving `youtube.com` is expected in v1.3.4 because YouTube remains outside DNS blocking so IINA continues to work.

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

