import Foundation
import AppKit
import ApplicationServices
import Darwin
import DeadlockShared

final class DeadlockDaemon {
    private let store: ConfigStore
    private let server: UnixSocketServer
    private var boundaryTimer: DispatchSourceTimer?
    private var powerMonitor: PowerMonitor?
    private var contentMonitor: ContentMonitor?
    private let webProtection = WebProtection()
    private let browserPolicyProtection = BrowserPolicyProtection()
    private let queue = DispatchQueue(label: "deadlock.state")

    private var warnedForStart: Date?
    private var launchedCountdownForStart: Date?
    private var testInterval: LockInterval?
    private var emergencyChallenge: String?
    private var emergencyReadyAt: Date?
    private var emergencyOverrideUntil: Date?
    private var lastWebProtectionFingerprint: String?
    private var nextWebProtectionRefreshAt: Date?
    private var nextWebProtectionRetryAt: Date?
    private var nextWebProtectionHealthCheckAt: Date?
    private let webProtectionHealthCheckInterval: TimeInterval = 5 * 60
    private var webProtectionRetryDelay: TimeInterval = 60
    private var webProtectionLastError: String?

    init() throws {
        store = try ConfigStore()
        server = try UnixSocketServer()
    }

    func run() {
        ensurePornSettings()
        ensureDistractionSettings()

        powerMonitor = PowerMonitor { [weak self] in
            self?.queue.asyncAfter(deadline: .now() + 2) { self?.evaluate(reason: "wake") }
        }
        powerMonitor?.start()

        contentMonitor = ContentMonitor(configProvider: { [weak self] in
            guard let self else { return .defaultConfig }
            return self.queue.sync {
                var config = self.store.state.current
                let pornActive = self.pornProtectionActive()
                let distractionActive = self.distractionWebProtectionEnabled()
                config.contentFilterEnabled = pornActive || distractionActive

                var terms: [String] = []
                if pornActive {
                    terms.append(contentsOf: LockConfig.defaultBlockedWords)
                }
                if distractionActive {
                    terms.append(contentsOf: PolicyEngine.normalizedDomains(
                        self.effectiveDistractionSettings().blockedDomains
                    ))
                }
                config.blockedWords = Array(Set(terms)).sorted()
                return config
            }
        }, onMatch: { [weak self] pid, word in
            self?.terminateMatchedApplication(pid: pid, word: word)
        })
        contentMonitor?.start()

        applyWebProtectionIfNeeded(force: true)
        Thread.detachNewThread { [weak self] in self?.acceptLoop() }
        evaluate(reason: "startup")
        RunLoop.main.run()
    }

    private func ensurePornSettings() {
        guard store.state.pornSettings == nil else { return }
        let migratedEnabled = store.state.accountabilityEnabled ?? true
        try? store.mutate { state in
            var settings = PornSettings.defaultSettings
            settings.accountabilityEnabled = migratedEnabled
            state.pornSettings = settings
        }
    }

    private func effectivePornSettings() -> PornSettings {
        store.state.pornSettings ?? .defaultSettings
    }

    private func ensureDistractionSettings() {
        guard store.state.distractionSettings == nil else { return }
        try? store.mutate { state in
            state.distractionSettings = .defaultSettings
        }
    }

    private func effectiveDistractionSettings() -> DistractionSettings {
        store.state.distractionSettings ?? .defaultSettings
    }

    private func acceptLoop() {
        while true {
            do {
                let fd = try server.acceptClient()
                autoreleasepool { handleClient(fd) }
                close(fd)
            } catch {
                sleep(1)
            }
        }
    }

    private func allowedClient(_ fd: Int32) -> Bool {
        guard let uid = UnixSocketServer.peerUID(fd) else { return false }
        if uid == 0 { return true }
        return consoleUID() == uid
    }

    private func handleClient(_ fd: Int32) {
        guard allowedClient(fd) else {
            try? FramedJSON.send(IPCResponse(ok: false, message: "Client UID is not the active console user."), to: fd)
            return
        }
        do {
            let req = try FramedJSON.receive(IPCRequest.self, from: fd)
            let response = queue.sync { self.process(req) }
            try FramedJSON.send(response, to: fd)
        } catch {
            try? FramedJSON.send(IPCResponse(ok: false, message: "IPC error: \(error)"), to: fd)
        }
    }

    private func process(_ req: IPCRequest) -> IPCResponse {
        applyPendingIfDue()
        switch req.command {
        case .getStatus:
            return IPCResponse(ok: true, message: "ok", status: status(), pornSettings: effectivePornSettings(), distractionSettings: effectiveDistractionSettings())

        case .getConfig:
            return IPCResponse(ok: true, message: "ok", status: status(), config: store.state.current, pornSettings: effectivePornSettings(), distractionSettings: effectiveDistractionSettings())

        case .setConfig:
            guard var new = req.config else { return IPCResponse(ok: false, message: "Missing config") }
            if let until = store.state.settingsLockedUntil, until > Date() {
                return IPCResponse(ok: false, message: "Settings are locked until \(ISO8601DateFormatter().string(from: until)).", status: status(), config: store.state.current)
            }
            guard !status().configChangesBlocked else {
                return IPCResponse(ok: false, message: "Schedule changes are blocked while active or within 5 minutes of a sleep lock.", status: status(), config: store.state.current)
            }
            // The content quit filter is daemon-owned and cannot be edited from the GUI.
            new.contentFilterEnabled = false
            new.blockedWords = LockConfig.defaultBlockedWords
            let loosening = ScheduleEngine.isLoosening(from: store.state.current, to: new)
            do {
                if loosening {
                    let date = Date().addingTimeInterval(24 * 3600)
                    try store.mutate { $0.pending = PendingConfig(config: new, activatesAt: date) }
                    reschedule()
                    return IPCResponse(ok: true, message: "Loosening change queued for 24 hours.", status: status(), config: store.state.current)
                } else {
                    try store.mutate { $0.current = new; $0.pending = nil }
                    reschedule(); evaluate(reason: "config-tightened")
                    return IPCResponse(ok: true, message: "Schedule applied immediately.", status: status(), config: store.state.current)
                }
            } catch {
                return IPCResponse(ok: false, message: "Could not save config: \(error)")
            }

        case .startTest:
            let start = Date().addingTimeInterval(60)
            testInterval = LockInterval(start: start, end: start.addingTimeInterval(120))
            warnedForStart = nil
            launchedCountdownForStart = nil
            reschedule(); evaluate(reason: "test")
            return IPCResponse(ok: true, message: "Test armed: 60-second warning, then a 2-minute sleep-lock window.", status: status())

        case .startPornBlocker:
            let now = Date()
            let until = PolicyEngine.boundedEndDate(
                now: now,
                seconds: req.seconds,
                customDate: req.date,
                minimum: PolicyEngine.minimumPornDuration,
                maximum: PolicyEngine.maximumPornDuration,
                fallback: 4 * 3600
            )
            do {
                try store.mutate { state in
                    state.pornBlockerUntil = max(state.pornBlockerUntil ?? .distantPast, until)
                }
                applyWebProtectionIfNeeded(force: true)
                contentMonitor?.rescanFrontmost()
                reschedule()
                return IPCResponse(ok: true, message: "Porn Blocker locked until \(ISO8601DateFormatter().string(from: store.state.pornBlockerUntil ?? until)).", status: status(), pornSettings: effectivePornSettings())
            } catch {
                return IPCResponse(ok: false, message: "Could not start Porn Blocker: \(error)")
            }

        case .startDistractionBlock:
            let now = Date()
            let until = PolicyEngine.boundedEndDate(
                now: now,
                seconds: req.seconds,
                customDate: req.date,
                minimum: PolicyEngine.minimumDistractionDuration,
                maximum: PolicyEngine.maximumDistractionDuration,
                fallback: 60 * 60
            )
            do {
                try store.mutate { state in
                    state.distractionBlockUntil = max(
                        state.distractionBlockUntil ?? .distantPast,
                        until
                    )
                }
                applyWebProtectionIfNeeded(force: true)
                reschedule()
                return IPCResponse(
                    ok: true,
                    message: "Distractions locked until \(ISO8601DateFormatter().string(from: store.state.distractionBlockUntil ?? until)).",
                    status: status(),
                    distractionSettings: effectiveDistractionSettings()
                )
            } catch {
                return IPCResponse(
                    ok: false,
                    message: "Could not start distraction block: \(error)",
                    status: status()
                )
            }

        case .setDistractionSettings:
            guard var new = req.distractionSettings else {
                return IPCResponse(
                    ok: false,
                    message: "Missing distraction settings.",
                    status: status(),
                    distractionSettings: effectiveDistractionSettings()
                )
            }
            let now = Date()
            if let until = store.state.settingsLockedUntil, until > now {
                return IPCResponse(
                    ok: false,
                    message: "Settings are locked until \(ISO8601DateFormatter().string(from: until)).",
                    status: status(),
                    distractionSettings: effectiveDistractionSettings()
                )
            }
            if distractionProtectionActive(now) {
                return IPCResponse(
                    ok: false,
                    message: "Distraction settings cannot be weakened while a distraction block is active.",
                    status: status(),
                    distractionSettings: effectiveDistractionSettings()
                )
            }

            new.days = PolicyEngine.normalizedDays(new.days)
            new.blockedDomains = PolicyEngine.normalizedDomains(new.blockedDomains)
            new.setupCompleted = true

            do {
                try store.mutate { state in
                    state.distractionSettings = new
                }
                applyWebProtectionIfNeeded(force: true)
                reschedule()
                return IPCResponse(
                    ok: true,
                    message: "Distraction settings saved.",
                    status: status(),
                    distractionSettings: new
                )
            } catch {
                return IPCResponse(
                    ok: false,
                    message: "Could not save distraction settings: \(error)",
                    status: status()
                )
            }

        case .setPornSettings:
            guard var new = req.pornSettings else {
                return IPCResponse(ok: false, message: "Missing Porn Blocker settings.", status: status(), pornSettings: effectivePornSettings())
            }
            let now = Date()
            if let until = store.state.settingsLockedUntil, until > now {
                return IPCResponse(ok: false, message: "Settings are locked until \(ISO8601DateFormatter().string(from: until)).", status: status(), pornSettings: effectivePornSettings())
            }
            if pornProtectionActive(now) {
                return IPCResponse(ok: false, message: "Porn Blocker settings cannot be changed while a mandatory/manual protection window is active.", status: status(), pornSettings: effectivePornSettings())
            }
            let existing = effectivePornSettings()
            let firstSetup = existing.setupCompleted != true
            let weekday = Calendar.current.component(.weekday, from: now)
            if !firstSetup && weekday != existing.editWeekday {
                return IPCResponse(ok: false, message: "Porn Blocker schedule can only be edited on \(weekdayName(existing.editWeekday)).", status: status(), pornSettings: existing)
            }
            new.editWeekday = min(7, max(1, new.editWeekday))
            new.accountabilityRecipient = String(new.accountabilityRecipient.trimmingCharacters(in: .whitespacesAndNewlines).prefix(256))
            new.days = PolicyEngine.normalizedDays(new.days)
            new.setupCompleted = true
            do {
                try store.mutate { state in
                    state.pornSettings = new
                    state.accountabilityEnabled = new.accountabilityEnabled
                }
                applyWebProtectionIfNeeded(force: true)
                reschedule()
                return IPCResponse(ok: true, message: "Porn Blocker settings saved. Future edits are only allowed on \(weekdayName(new.editWeekday)).", status: status(), pornSettings: new)
            } catch {
                return IPCResponse(ok: false, message: "Could not save Porn Blocker settings: \(error)")
            }

        case .lockSettings:
            let now = Date()
            let until = PolicyEngine.boundedEndDate(
                now: now,
                seconds: req.seconds,
                customDate: req.date,
                minimum: PolicyEngine.minimumSettingsGuardDuration,
                maximum: PolicyEngine.maximumSettingsGuardDuration,
                fallback: 7 * 24 * 3600
            )
            do {
                try store.mutate { state in
                    state.settingsLockedUntil = max(state.settingsLockedUntil ?? .distantPast, until)
                    // A newly-created guard must not leave a previously queued
                    // weakening waiting to activate underneath it.
                    state.pending = nil
                }
                reschedule()
                return IPCResponse(ok: true, message: "Settings locked until \(ISO8601DateFormatter().string(from: store.state.settingsLockedUntil ?? until)). Any queued sleep weakening was cancelled.", status: status())
            } catch {
                return IPCResponse(ok: false, message: "Could not lock settings: \(error)")
            }

        case .clearAccountability:
            do {
                try store.mutate { state in
                    state.accountabilityTriggeredAt = nil
                    state.accountabilityReason = nil
                }
                return IPCResponse(ok: true, message: "ok", status: status())
            } catch {
                return IPCResponse(ok: false, message: "Could not clear accountability event: \(error)", status: status())
            }

        case .emergencyBegin:
            let challenge = randomChallenge(length: 200)
            emergencyChallenge = challenge
            emergencyReadyAt = nil
            return IPCResponse(ok: true, message: "Type the 200-character challenge exactly. The 30-minute wait starts after it matches.", status: status(), challenge: challenge)

        case .emergencySubmit:
            guard let expected = emergencyChallenge, let text = req.text, constantTimeEqual(expected, text) else {
                return IPCResponse(ok: false, message: "Challenge did not match.", status: status())
            }
            emergencyChallenge = nil
            emergencyReadyAt = Date().addingTimeInterval(30 * 60)
            reschedule()
            return IPCResponse(ok: true, message: "Challenge accepted. Emergency sleep override unlocks in 30 minutes.", status: status())

        case .emergencyActivate:
            guard let ready = emergencyReadyAt, Date() >= ready else {
                return IPCResponse(ok: false, message: "Emergency wait has not finished.", status: status())
            }
            emergencyOverrideUntil = Date().addingTimeInterval(2 * 3600)
            emergencyReadyAt = nil
            reschedule()
            return IPCResponse(ok: true, message: "Emergency sleep override active for 2 hours. Porn Blocker schedules are unaffected.", status: status())

        case .uninstallRequest:
            do {
                if store.state.uninstallRequestedAt == nil {
                    try store.mutate { $0.uninstallRequestedAt = Date() }
                    return IPCResponse(ok: true, message: "Uninstall cooldown started. Re-run uninstall.sh after 24 hours.", status: status())
                }
                return IPCResponse(ok: true, message: uninstallMessage(), status: status())
            } catch {
                return IPCResponse(ok: false, message: "Could not store uninstall request: \(error)")
            }

        case .uninstallStatus:
            let ready = uninstallReadyDate()
            if let ready, Date() >= ready { return IPCResponse(ok: true, message: "READY", status: status()) }
            return IPCResponse(ok: false, message: uninstallMessage(), status: status())
        }
    }

    private func currentInterval(now: Date = Date()) -> LockInterval? {
        if let test = testInterval, test.start <= now && now < test.end { return test }
        return ScheduleEngine.activeInterval(at: now, config: store.state.current)
    }

    private func nextInterval(now: Date = Date()) -> LockInterval? {
        var candidates: [LockInterval] = []
        if let test = testInterval, test.start > now { candidates.append(test) }
        if let scheduled = ScheduleEngine.nextInterval(after: now, config: store.state.current) { candidates.append(scheduled) }
        return candidates.min { $0.start < $1.start }
    }

    private func pornScheduleConfig() -> LockConfig {
        let settings = effectivePornSettings()
        // A migrated/fresh install gets one real setup opportunity before the
        // default 4–8 PM mandatory window begins enforcing. After the first
        // save, setupCompleted is true and the chosen schedule is strict.
        let scheduleEnabled = settings.scheduleEnabled && settings.setupCompleted == true
        return LockConfig(
            enabled: scheduleEnabled,
            days: settings.days,
            contentFilterEnabled: false,
            blockedWords: LockConfig.defaultBlockedWords
        )
    }

    private func scheduledPornInterval(now: Date = Date()) -> LockInterval? {
        ScheduleEngine.activeInterval(at: now, config: pornScheduleConfig())
    }

    private func nextScheduledPornInterval(now: Date = Date()) -> LockInterval? {
        ScheduleEngine.nextInterval(after: now, config: pornScheduleConfig())
    }

    private func pornProtectionActive(_ now: Date = Date()) -> Bool {
        if let manual = store.state.pornBlockerUntil, manual > now { return true }
        return scheduledPornInterval(now: now) != nil
    }

    private func distractionScheduleConfig() -> LockConfig {
        let settings = effectiveDistractionSettings()
        return LockConfig(
            enabled: settings.scheduleEnabled,
            days: settings.days,
            contentFilterEnabled: false,
            blockedWords: LockConfig.defaultBlockedWords
        )
    }

    private func scheduledDistractionInterval(now: Date = Date()) -> LockInterval? {
        ScheduleEngine.activeInterval(at: now, config: distractionScheduleConfig())
    }

    private func nextScheduledDistractionInterval(now: Date = Date()) -> LockInterval? {
        ScheduleEngine.nextInterval(after: now, config: distractionScheduleConfig())
    }

    private func distractionProtectionActive(_ now: Date = Date()) -> Bool {
        if let manual = store.state.distractionBlockUntil, manual > now { return true }
        return scheduledDistractionInterval(now: now) != nil
    }

    private func distractionWebProtectionEnabled(_ now: Date = Date()) -> Bool {
        let settings = effectiveDistractionSettings()
        let domains = PolicyEngine.normalizedDomains(settings.blockedDomains)
        guard !domains.isEmpty else { return false }

        // With no weekly schedule configured, the distraction list behaves
        // like a normal always-on blocker. A schedule narrows enforcement to
        // its active/manual windows.
        if !settings.scheduleEnabled { return true }
        return distractionProtectionActive(now)
    }

    private func distractionSettingsEditable(_ now: Date = Date()) -> Bool {
        PolicyEngine.distractionSettingsEditable(
            now: now,
            distractionProtectionActive: distractionProtectionActive(now),
            settingsLockedUntil: store.state.settingsLockedUntil
        )
    }

    private func overrideActive(_ now: Date = Date()) -> Bool {
        if let until = emergencyOverrideUntil, until > now { return true }
        return false
    }

    private func pornSettingsEditableToday(_ now: Date = Date()) -> Bool {
        PolicyEngine.pornSettingsEditable(
            now: now,
            settings: effectivePornSettings(),
            pornProtectionActive: pornProtectionActive(now),
            settingsLockedUntil: store.state.settingsLockedUntil
        )
    }

    private func status() -> DaemonStatus {
        let now = Date()
        let active = currentInterval(now: now)
        let next = nextInterval(now: now)
        let scheduledPorn = scheduledPornInterval(now: now)
        let nextPorn = nextScheduledPornInterval(now: now)
        let scheduledDistraction = scheduledDistractionInterval(now: now)
        let nextDistraction = nextScheduledDistractionInterval(now: now)
        let settingsGuard = (store.state.settingsLockedUntil ?? .distantPast) > now
        let blocked = settingsGuard || active != nil || (next.map { $0.start.timeIntervalSince(now) <= 300 } ?? false)
        let pornSettings = effectivePornSettings()

        return DaemonStatus(
            active: active != nil && !overrideActive(now),
            nextLockStart: next?.start,
            activeEnd: active?.end,
            pendingConfigActivation: store.state.pending?.activatesAt,
            configChangesBlocked: blocked,
            emergencyReadyAt: emergencyReadyAt,
            emergencyOverrideUntil: emergencyOverrideUntil,
            uninstallReadyAt: uninstallReadyDate(),
            testWindowStart: testInterval?.start,
            testWindowEnd: testInterval?.end,
            pornBlockerUntil: store.state.pornBlockerUntil,
            pornBlockerActive: pornProtectionActive(now),
            pornScheduledEnd: scheduledPorn?.end,
            pornScheduleNextStart: nextPorn?.start,
            pornSettingsEditableToday: pornSettingsEditableToday(now),
            settingsLockedUntil: store.state.settingsLockedUntil,
            accountabilityEnabled: pornSettings.accountabilityEnabled,
            accountabilityTriggeredAt: store.state.accountabilityTriggeredAt,
            accountabilityReason: store.state.accountabilityReason,
            webProtectionHealthy: {
                let distractionsEnabled = distractionWebProtectionEnabled(now)
                let domains = PolicyEngine.normalizedDomains(
                    effectiveDistractionSettings().blockedDomains
                )
                let youtubeBlocked = distractionsEnabled
                    && domains.contains(where: isYouTubeDomain)
                return webProtection.isHealthy(
                    pornEnabled: pornProtectionActive(now),
                    distractionsEnabled: distractionsEnabled,
                    distractionDomains: domains
                ) && browserPolicyProtection.isHealthy(
                    youtubeBlocked: youtubeBlocked
                )
            }(),
            webProtectionLastError: webProtectionLastError,
            distractionBlockUntil: store.state.distractionBlockUntil,
            distractionBlockActive: distractionWebProtectionEnabled(now),
            distractionScheduledEnd: scheduledDistraction?.end,
            distractionScheduleNextStart: nextDistraction?.start,
            distractionSettingsEditable: distractionSettingsEditable(now)
        )
    }

    private func uninstallReadyDate() -> Date? {
        store.state.uninstallRequestedAt?.addingTimeInterval(24 * 3600)
    }

    private func uninstallMessage() -> String {
        guard let ready = uninstallReadyDate() else { return "No uninstall cooldown has been requested." }
        return "Uninstall is available after \(ISO8601DateFormatter().string(from: ready))."
    }

    private func applyPendingIfDue() {
        let now = Date()
        guard let pending = store.state.pending, pending.activatesAt <= now else { return }

        // Never let a delayed loosening truncate a sleep interval that already
        // started under the old policy. It becomes eligible at that interval's end.
        let oldActive = ScheduleEngine.activeInterval(at: now, config: store.state.current)
        let safeDate = PolicyEngine.safePendingActivationDate(
            now: now,
            pendingActivation: pending.activatesAt,
            activeOldInterval: oldActive
        )

        if safeDate > now {
            if abs(safeDate.timeIntervalSince(pending.activatesAt)) > 0.5 {
                try? store.mutate { state in
                    guard var current = state.pending else { return }
                    current.activatesAt = safeDate
                    state.pending = current
                }
            }
            return
        }

        try? store.mutate { state in
            state.current = pending.config
            state.pending = nil
        }
    }

    private func evaluate(reason: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.store.reloadIfValid()
            self.ensurePornSettings()
            self.ensureDistractionSettings()
            self.applyPendingIfDue()
            let now = Date()
            if let test = self.testInterval, now >= test.end { self.testInterval = nil }
            if let until = self.emergencyOverrideUntil, now >= until { self.emergencyOverrideUntil = nil }
            if let manual = self.store.state.pornBlockerUntil, now >= manual {
                try? self.store.mutate { $0.pornBlockerUntil = nil }
            }
            if let manual = self.store.state.distractionBlockUntil, now >= manual {
                try? self.store.mutate { $0.distractionBlockUntil = nil }
            }

            self.applyWebProtectionIfNeeded()
            if self.pornProtectionActive(now) || self.distractionWebProtectionEnabled(now) {
                self.contentMonitor?.rescanFrontmost()
            }

            if let active = self.currentInterval(now: now), !self.overrideActive(now) {
                self.forceSleep()
                self.scheduleTimer(at: min(active.end, now.addingTimeInterval(10)))
                return
            }

            if let next = self.nextInterval(now: now) {
                let remaining = next.start.timeIntervalSince(now)
                if remaining <= 300, remaining > 60, self.warnedForStart != next.start {
                    self.warnedForStart = next.start
                    notifyConsole(title: "deadlock", body: "Sleep lock begins in 5 minutes. Save your work.")
                }
                if remaining <= 60, remaining > 0, self.launchedCountdownForStart != next.start {
                    self.launchedCountdownForStart = next.start
                    launchGUIForCountdown()
                }
            }
            self.reschedule()
        }
    }

    private func reschedule() {
        let now = Date()
        var dates: [Date] = []
        if let active = currentInterval(now: now) { dates.append(active.end) }
        if let next = nextInterval(now: now) {
            for date in [next.start.addingTimeInterval(-300), next.start.addingTimeInterval(-60), next.start] where date > now {
                dates.append(date)
            }
        }
        if let pending = store.state.pending?.activatesAt, pending > now { dates.append(pending) }
        if let ready = emergencyReadyAt, ready > now { dates.append(ready) }
        if let until = emergencyOverrideUntil, until > now { dates.append(until) }
        if let end = testInterval?.end, end > now { dates.append(end) }
        if let manual = store.state.pornBlockerUntil, manual > now { dates.append(manual) }
        if let scheduled = scheduledPornInterval(now: now) { dates.append(scheduled.end) }
        if let nextPorn = nextScheduledPornInterval(now: now) { dates.append(nextPorn.start) }
        if let manual = store.state.distractionBlockUntil, manual > now { dates.append(manual) }
        if let scheduled = scheduledDistractionInterval(now: now) { dates.append(scheduled.end) }
        if let nextDistraction = nextScheduledDistractionInterval(now: now) { dates.append(nextDistraction.start) }
        if let settingsEnd = store.state.settingsLockedUntil, settingsEnd > now { dates.append(settingsEnd) }
        if let refresh = nextWebProtectionRefreshAt, refresh > now { dates.append(refresh) }
        if let retry = nextWebProtectionRetryAt, retry > now { dates.append(retry) }
        if (pornProtectionActive(now) || distractionWebProtectionEnabled(now)),
           let health = nextWebProtectionHealthCheckAt,
           health > now {
            dates.append(health)
        }

        if let next = dates.filter({ $0 > now }).min() { scheduleTimer(at: next) }
        else { boundaryTimer?.cancel(); boundaryTimer = nil }
    }

    private func scheduleTimer(at date: Date) {
        boundaryTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + max(0.05, date.timeIntervalSinceNow), leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.evaluate(reason: "timer") }
        boundaryTimer = timer
        timer.resume()
    }

    // Keep the proven sleep mechanism unchanged.
    private func forceSleep() {
        _ = runProcess("/usr/bin/pmset", ["sleepnow"])
    }

    private func terminateMatchedApplication(pid: pid_t, word: String) {
        queue.async {
            let pornActive = self.pornProtectionActive()
            let distractionActive = self.distractionWebProtectionEnabled()
            guard pornActive || distractionActive else { return }
            guard pid > 1, pid != getpid() else { return }

            let app = NSRunningApplication(processIdentifier: pid)
            if let bundle = app?.bundleIdentifier,
               [
                    "local.deadlock.BedtimeLock",
                    "com.apple.loginwindow",
                    "com.apple.WindowServer",
                    "com.apple.MobileSMS"
               ].contains(bundle) {
                return
            }

            let normalizedWord = word.lowercased()
            let distractionDomains = PolicyEngine.normalizedDomains(
                self.effectiveDistractionSettings().blockedDomains
            )
            let isDistractionMatch = distractionActive && distractionDomains.contains {
                $0 == normalizedWord
                    || (self.isYouTubeDomain($0) && self.isYouTubeDomain(normalizedWord))
            }

            if isDistractionMatch {
                let isBrowser = self.isSupportedBrowser(app?.bundleIdentifier)
                let isYouTubeApp = self.isYouTubeDomain(normalizedWord)
                    && self.isOfficialYouTubeApp(app)
                guard isBrowser || isYouTubeApp else { return }

                if isBrowser, self.closeFocusedBrowserWindow(pid: pid) {
                    notifyConsole(
                        title: "deadlock",
                        body: self.isYouTubeDomain(normalizedWord)
                            ? "Closed the YouTube browser window. IINA remains available."
                            : "Closed the browser window showing a blocked distraction site."
                    )
                    return
                }

                // If Accessibility cannot close the focused browser window, fail
                // closed rather than leaving the blocked site usable.
                _ = Darwin.kill(pid, SIGTERM)
                self.queue.asyncAfter(deadline: .now() + 1) {
                    if Darwin.kill(pid, 0) == 0 {
                        _ = Darwin.kill(pid, SIGKILL)
                    }
                }
                notifyConsole(
                    title: "deadlock",
                    body: self.isYouTubeDomain(normalizedWord)
                        ? "Blocked YouTube in the browser/app. IINA remains available."
                        : "Closed a browser showing a blocked distraction site."
                )
                return
            }

            guard pornActive else { return }
            let settings = self.effectivePornSettings()
            let wantsOverlay = settings.motivationalOverlayEnabled
            let wantsMessage = settings.accountabilityEnabled
                && !settings.accountabilityRecipient.isEmpty
            let now = Date()
            let mayTrigger = PolicyEngine.accountabilityMayTrigger(
                now: now,
                lastTriggeredAt: self.store.state.lastAccountabilityTriggeredAt
            )
            if mayTrigger && (wantsOverlay || wantsMessage) {
                try? self.store.mutate { state in
                    state.lastAccountabilityTriggeredAt = now
                    state.accountabilityTriggeredAt = now
                    state.accountabilityReason = word
                }
                launchGUIForCountdown()
            }

            _ = Darwin.kill(pid, SIGTERM)
            self.queue.asyncAfter(deadline: .now() + 2) {
                if Darwin.kill(pid, 0) == 0 {
                    _ = Darwin.kill(pid, SIGKILL)
                }
            }
            notifyConsole(
                title: "deadlock",
                body: "Blocked adult content and closed the app."
            )
        }
    }

    private func closeFocusedBrowserWindow(pid: pid_t) -> Bool {
        let application = AXUIElementCreateApplication(pid)

        var focusedWindowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindowValue
        ) == .success,
              let focusedWindow = focusedWindowValue
        else {
            return false
        }

        let window = focusedWindow as! AXUIElement
        var closeButtonValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window,
            kAXCloseButtonAttribute as CFString,
            &closeButtonValue
        ) == .success,
              let closeButton = closeButtonValue
        else {
            return false
        }

        return AXUIElementPerformAction(
            closeButton as! AXUIElement,
            kAXPressAction as CFString
        ) == .success
    }

    private func isYouTubeDomain(_ value: String) -> Bool {
        let host = value.lowercased()
        return host == "youtube.com"
            || host.hasSuffix(".youtube.com")
            || host == "youtu.be"
            || host.hasSuffix(".youtu.be")
            || host == "youtube-nocookie.com"
            || host.hasSuffix(".youtube-nocookie.com")
    }

    private func isOfficialYouTubeApp(_ app: NSRunningApplication?) -> Bool {
        guard let app else { return false }
        let bundle = (app.bundleIdentifier ?? "").lowercased()
        if bundle.contains("iina") { return false }
        if bundle == "com.google.ios.youtube" || bundle == "com.google.youtube" {
            return true
        }
        return app.localizedName?.lowercased() == "youtube"
            && (bundle.contains("safari")
                || bundle.contains("chrome")
                || bundle.contains("google"))
    }

    private func isSupportedBrowser(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        let exact: Set<String> = [
            "com.apple.Safari",
            "com.google.Chrome",
            "org.mozilla.firefox",
            "company.thebrowser.Browser",
            "com.brave.Browser",
            "com.microsoft.edgemac",
            "com.kagi.kagimacOS",
            "com.vivaldi.Vivaldi",
            "com.operasoftware.Opera"
        ]
        if exact.contains(bundleIdentifier) { return true }
        let value = bundleIdentifier.lowercased()
        return value.contains("browser")
            || value.contains("chrome")
            || value.contains("firefox")
            || value.contains("safari")
    }

    private func applyWebProtectionIfNeeded(force: Bool = false) {
        let now = Date()
        let pornEnabled = pornProtectionActive(now)
        let distractionsEnabled = distractionWebProtectionEnabled(now)
        let protectionsActive = pornEnabled || distractionsEnabled
        let domains = PolicyEngine.normalizedDomains(
            effectiveDistractionSettings().blockedDomains
        )
        let youtubeBlocked = distractionsEnabled
            && domains.contains(where: isYouTubeDomain)
        let fingerprint = [
            pornEnabled ? "porn:1" : "porn:0",
            distractionsEnabled ? "distractions:1" : "distractions:0",
            youtubeBlocked ? "youtube-browser:1" : "youtube-browser:0",
            domains.joined(separator: ",")
        ].joined(separator: "|")

        let fingerprintChanged = lastWebProtectionFingerprint != fingerprint
        let refreshDue = pornEnabled
            && (nextWebProtectionRefreshAt.map { $0 <= now } ?? false)
        let retryDue = nextWebProtectionRetryAt.map { $0 <= now } ?? false
        let healthDue = protectionsActive
            && (nextWebProtectionHealthCheckAt.map { $0 <= now } ?? true)

        // Most daemon evaluations are sleep/schedule events. Avoid re-reading
        // /etc/hosts on every one; active web protection gets a five-minute
        // integrity check using the existing single boundary timer.
        if !force,
           !fingerprintChanged,
           !refreshDue,
           !retryDue,
           !healthDue {
            return
        }

        let healthy = webProtection.isHealthy(
            pornEnabled: pornEnabled,
            distractionsEnabled: distractionsEnabled,
            distractionDomains: domains
        ) && browserPolicyProtection.isHealthy(
            youtubeBlocked: youtubeBlocked
        )

        if !force,
           !fingerprintChanged,
           !refreshDue,
           !retryDue,
           healthy {
            nextWebProtectionHealthCheckAt = protectionsActive
                ? now.addingTimeInterval(webProtectionHealthCheckInterval)
                : nil
            return
        }

        do {
            let nextRefresh = try webProtection.apply(
                pornEnabled: pornEnabled,
                distractionsEnabled: distractionsEnabled,
                distractionDomains: domains,
                forceRefresh: force || refreshDue,
                now: now
            )
            try browserPolicyProtection.apply(
                youtubeBlocked: youtubeBlocked
            )
            lastWebProtectionFingerprint = fingerprint
            nextWebProtectionRefreshAt = nextRefresh
            nextWebProtectionRetryAt = nil
            nextWebProtectionHealthCheckAt = protectionsActive
                ? now.addingTimeInterval(webProtectionHealthCheckInterval)
                : nil
            webProtectionRetryDelay = 60
            webProtectionLastError = nil
        } catch {
            webProtectionLastError = String(describing: error)
            nextWebProtectionRetryAt = now.addingTimeInterval(webProtectionRetryDelay)
            nextWebProtectionHealthCheckAt = nil
            webProtectionRetryDelay = min(webProtectionRetryDelay * 2, 3600)
            NSLog("deadlock: web protection update failed: \(error)")
        }
    }

    private func weekdayName(_ weekday: Int) -> String {
        let names = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        return names[min(7, max(1, weekday)) - 1]
    }

    private func randomChallenge(length: Int) -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789")
        var result = ""
        result.reserveCapacity(length)
        for _ in 0..<length { result.append(alphabet.randomElement()!) }
        return result
    }

    private func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var diff = x.count ^ y.count
        let count = max(x.count, y.count)
        for i in 0..<count { diff |= Int((i < x.count ? x[i] : 0) ^ (i < y.count ? y[i] : 0)) }
        return diff == 0
    }
}
