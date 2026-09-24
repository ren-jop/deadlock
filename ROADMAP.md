# deadlock roadmap

## Current architecture

- **deadlock menu app**: minimal settings/status UI only, no Dock icon.
- **bedtimelockd**: root enforcement daemon and source of truth.
- **watchdog**: repairs/restarts root enforcement components.
- **launch at login**: a per-user LaunchAgent directly runs the menu app and keeps the menu icon present.
- **event-driven scheduling**: sleep, Porn Blocker, distractions, Settings Guard and web-protection refresh share daemon timers rather than polling loops.

## Sleep Lock — stable

Do not redesign the working sleep path.

- IOKit wake notifications.
- `pmset sleepnow` enforcement.
- re-sleep during an active window.
- 5-minute warning and final countdown.
- 2-minute test mode.
- delayed loosening changes.

## Distractions — Cold Turkey core replacement

Implemented around the useful core: strict website blocking, not feature bloat.

- separate root-owned distraction policy.
- default list: Instagram, TikTok, X/Twitter, Reddit, Facebook and Twitch.
- YouTube intentionally remains unblocked by default.
- user-editable domain list.
- manual timed blocks from 5 minutes through custom dates.
- per-weekday schedules.
- active blocks cannot be weakened or edited before they end.
- Settings Guard also protects distraction settings.
- `/etc/hosts` is only rewritten when policy changes, activates/expires, or needs repair.
- **Focus app bridge**: `/Applications/deadlock.app/Contents/MacOS/deadlock --ipc focus-start <seconds>`
  lets the Focus timer start the same root-owned distraction lock without keeping the deadlock UI open.
- stopping Focus early does not weaken the already-started deadlock block.

Next distraction work:

- named profiles such as Study / Deep Work / Custom.
- allow-list exceptions for services that share large domains/CDNs.
- optional delayed weakening for inactive scheduled profiles.
- event-driven `/etc/hosts` tamper repair.

## Porn Blocker — stricter separate policy

- mandatory per-weekday windows.
- manual timed lock.
- SafeSearch mappings including Ecosia.
- known adult-domain hosts blocking.
- Accessibility text/URL fallback.
- immutable adult blocked-word filter.
- optional friend accountability.
- settings-edit weekday and Settings Guard.

Porn Blocker remains independent from ordinary distraction blocking.

## Reliability / performance

- daemon target: effectively zero idle CPU.
- no OCR or screen capture.
- bounded event-driven Accessibility scans.
- no high-frequency hosts rewrites.
- menu UI polls status infrequently; daemon is authoritative.
- web-protection integrity checks are throttled to every 5 minutes while protection is active, using the existing boundary timer.
- menu app is automatically relaunched if it exits so the icon stays available.
- root enforcement continues independently of the menu UI.
- every upgrade backs up files before replacement.

## Acceptance checks

1. `swift build`
2. `./build.sh`
3. `./install.sh`
4. `./deadlock-smoke.sh`
5. `./deadlockctl doctor`
6. confirm `/Applications/deadlock.app` exists and `BedtimeLock.app` does not
7. log out/in and confirm the fox-lock menu icon returns
8. start a distraction block and confirm configured sites stop resolving
9. reboot during an active distraction/Porn block and confirm enforcement returns
10. `./deadlockctl perf` and verify near-zero idle daemon CPU

## Explicitly removed / out of scope

- Pomotroid integration or productivity-reward unlocking.
- OCR/image classification.
- claiming a local administrator cannot ultimately bypass local software using Recovery/Safe Mode/root access.
