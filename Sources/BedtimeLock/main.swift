import SwiftUI
import AppKit
import DeadlockShared
import Combine
import Darwin

@MainActor
final class AppState: ObservableObject {
    @Published var config: LockConfig = .defaultConfig
    @Published var pornSettings: PornSettings = .defaultSettings
    @Published var distractionSettings: DistractionSettings = .defaultSettings
    @Published var bedGuardSettings: BedGuardSettings = .defaultSettings
    @Published var bedGuardSensor = BedGuardSensorSnapshot()
    @Published var status = DaemonStatus(daemonRunning: false)
    @Published var message = ""
    @Published var emergencyChallenge = ""
    @Published var emergencyTyped = ""
    @Published var emergencyReason = ""
    @Published var pornDurationMinutes = 240
    @Published var distractionDurationMinutes = 60
    @Published var distractionCustomEnd = Date().addingTimeInterval(2 * 3600)
    @Published var pornCustomEnd = Date().addingTimeInterval(24 * 3600)
    @Published var settingsGuardHours = 168
    @Published var settingsGuardCustomEnd = Date().addingTimeInterval(7 * 24 * 3600)

    private var timer: Timer?
    private var countdownWindow: NSWindow?
    private var accountabilityWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var accountabilityAttemptedEvent: Date?
    private var emergencyMessageAttemptedEvent: Date?
    private var emergencyPromptVisible = false

    private lazy var airPodsBedGuard = AirPodsBedGuard(
        onSnapshot: { [weak self] snapshot in
            self?.bedGuardSensor = snapshot
        },
        onTrigger: { [weak self] in
            self?.triggerBedGuard()
        }
    )

    private lazy var browserYouTubeGuard = BrowserYouTubeGuard(
        shouldBlock: { [weak self] in
            guard let self else { return false }
            let configured = self.distractionSettings.blockedDomains.contains { value in
                let host = value
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                return host == "youtube.com"
                    || host.hasSuffix(".youtube.com")
                    || host == "youtu.be"
                    || host.hasSuffix(".youtu.be")
                    || host == "youtube-nocookie.com"
                    || host.hasSuffix(".youtube-nocookie.com")
            }
            guard configured else { return false }


            // No weekly schedule means the user's distraction list is an
            // always-on block. Otherwise, follow the daemon's active status.
            return !self.distractionSettings.scheduleEnabled
                || self.status.distractionBlockActive
        },
        onDiagnostic: { [weak self] diagnostic in
            self?.message = diagnostic
        }
    )

    init() {
        scheduleRefresh()
        browserYouTubeGuard.start()

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleSystemWake()
            }
        }

        // Do not block creation of the menu-bar item if the root daemon is
        // still starting. IPC has a timeout, but the UI should appear instantly.
        DispatchQueue.main.async { [weak self] in
            self?.refreshAll()
        }
    }

    func refreshAll() {
        do {
            let response = try UnixSocketClient.request(IPCRequest(command: .getConfig))
            if let config = response.config { self.config = config }
            if let pornSettings = response.pornSettings { self.pornSettings = pornSettings }
            if let distractionSettings = response.distractionSettings { self.distractionSettings = distractionSettings }
            if let bedGuardSettings = response.bedGuardSettings { applyBedGuardSettings(bedGuardSettings) }
            if let status = response.status { self.status = status }
            message = ""
            updateCountdownWindow()
            updateAccountabilityWindow()
            sendEmergencyAccessMessageIfNeeded()
            scheduleRefresh()
        } catch {
            status.daemonRunning = false
            message = "Daemon unavailable: \(error)"
        }
    }

    func refreshStatus() {
        do {
            let response = try UnixSocketClient.request(IPCRequest(command: .getStatus))
            if let status = response.status { self.status = status }
            if let pornSettings = response.pornSettings { self.pornSettings = pornSettings }
            if let distractionSettings = response.distractionSettings { self.distractionSettings = distractionSettings }
            if let bedGuardSettings = response.bedGuardSettings { applyBedGuardSettings(bedGuardSettings) }
            updateCountdownWindow()
            updateAccountabilityWindow()
            sendEmergencyAccessMessageIfNeeded()
        } catch {
            status.daemonRunning = false
        }
    }

    private func refreshInterval() -> TimeInterval {
        if status.active || status.pornBlockerActive || status.distractionBlockActive {
            return 20
        }
        if let next = status.nextLockStart,
           next.timeIntervalSinceNow > 0,
           next.timeIntervalSinceNow <= 10 * 60 {
            return 20
        }
        if settingsWindow?.isVisible == true ||
           countdownWindow?.isVisible == true ||
           accountabilityWindow?.isVisible == true {
            return 30
        }
        return 120
    }

    private func scheduleRefresh() {
        timer?.invalidate()

        let interval = refreshInterval()
        let refreshTimer = Timer(timeInterval: interval, repeats: false) {
            [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refreshStatus()
                self.scheduleRefresh()
            }
        }

        refreshTimer.tolerance = min(10, interval * 0.15)
        RunLoop.main.add(refreshTimer, forMode: .common)
        timer = refreshTimer
    }

    func saveSleepSchedule() {
        do {
            let response = try UnixSocketClient.request(IPCRequest(command: .setConfig, config: config))
            message = response.message
            if let config = response.config { self.config = config }
            if let status = response.status { self.status = status }
        } catch { message = String(describing: error) }
    }

    func savePornSettings() {
        do {
            let response = try UnixSocketClient.request(IPCRequest(command: .setPornSettings, pornSettings: pornSettings))
            message = response.message
            if let settings = response.pornSettings { pornSettings = settings }
            if let status = response.status { self.status = status }
        } catch { message = String(describing: error) }
    }

    func saveDistractionSettings() {
        do {
            let response = try UnixSocketClient.request(
                IPCRequest(
                    command: .setDistractionSettings,
                    distractionSettings: distractionSettings
                )
            )
            message = response.message
            if let settings = response.distractionSettings {
                distractionSettings = settings
            }
            if let status = response.status { self.status = status }
        } catch {
            message = String(describing: error)
        }
    }

    func allowInstagramDeveloperOneOff() {
        do {
            let response = try UnixSocketClient.request(
                IPCRequest(command: .allowInstagramDeveloperOneOff)
            )
            message = response.message
            if let settings = response.distractionSettings {
                distractionSettings = settings
            }
            if let status = response.status {
                self.status = status
            }
        } catch {
            message = String(describing: error)
        }
    }


    private func applyBedGuardSettings(_ settings: BedGuardSettings) {
        bedGuardSettings = settings
        airPodsBedGuard.update(settings: settings)
    }

    func setBedGuardEnabled(_ enabled: Bool) {
        var new = bedGuardSettings
        if enabled && new.poses.isEmpty {
            message = "Record at least one bed posture before enabling Bed Guard."
            return
        }
        new.enabled = enabled
        saveBedGuardSettings(new)
    }

    func recordBedGuardPose() {
        guard !status.configChangesBlocked else {
            message = "Bed Guard cannot be changed while sleep settings are locked by the current window."
            return
        }

        message = "Hold your normal laptop-in-bed position for 5 seconds."
        airPodsBedGuard.captureCurrentPose { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let pose):
                var new = self.bedGuardSettings
                if new.poses.count >= 4 {
                    new.poses.removeFirst()
                }
                new.poses.append(pose)
                self.saveBedGuardSettings(new)
            case .failure(let error):
                self.message = error.localizedDescription
            }
        }
    }

    func clearBedGuardPoses() {
        var new = bedGuardSettings
        new.enabled = false
        new.poses = []
        saveBedGuardSettings(new)
    }

    private func saveBedGuardSettings(_ settings: BedGuardSettings) {
        do {
            let response = try UnixSocketClient.request(
                IPCRequest(
                    command: .setBedGuardSettings,
                    bedGuardSettings: settings
                )
            )
            message = response.message
            if let saved = response.bedGuardSettings {
                applyBedGuardSettings(saved)
            }
            if let status = response.status {
                self.status = status
            }
        } catch {
            message = "Could not save Bed Guard: \(error)"
        }
    }

    private func triggerBedGuard() {
        do {
            let response = try UnixSocketClient.request(
                IPCRequest(command: .bedGuardTrigger)
            )
            message = response.message
            if let status = response.status {
                self.status = status
            }
            if let saved = response.bedGuardSettings {
                applyBedGuardSettings(saved)
            }
        } catch {
            message = "Bed Guard could not reach the daemon: \(error)"
        }
    }

    private func normalizedDistractionDomain(
        _ value: String
    ) -> String {
        var host = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if let url = URL(
            string: host.contains("://")
                ? host
                : "https://\(host)"
        ),
           let urlHost = url.host?.lowercased() {
            host = urlHost
        }

        while host.hasPrefix("www.") {
            host.removeFirst(4)
        }

        return host
    }

    func isDistractionPresetEnabled(
        _ preset: DistractionPreset
    ) -> Bool {
        let current = Set(
            distractionSettings.blockedDomains.map(
                normalizedDistractionDomain
            )
        )
        return preset.domains
            .map(normalizedDistractionDomain)
            .allSatisfy(current.contains)
    }

    func setDistractionPreset(
        _ preset: DistractionPreset,
        enabled: Bool
    ) {
        guard status.distractionSettingsEditable else { return }

        let targets = Set(
            preset.domains.map(normalizedDistractionDomain)
        )
        var values = distractionSettings.blockedDomains

        if enabled {
            var existing = Set(
                values.map(normalizedDistractionDomain)
            )
            for domain in preset.domains {
                let normalized =
                    normalizedDistractionDomain(domain)
                if !existing.contains(normalized) {
                    values.append(normalized)
                    existing.insert(normalized)
                }
            }
        } else {
            values.removeAll {
                targets.contains(
                    normalizedDistractionDomain($0)
                )
            }
        }

        distractionSettings.blockedDomains = values
    }

    func isDistractionGroupEnabled(
        _ group: DistractionPresetGroup
    ) -> Bool {
        group.presets.allSatisfy(
            isDistractionPresetEnabled
        )
    }

    func setDistractionGroup(
        _ group: DistractionPresetGroup,
        enabled: Bool
    ) {
        guard status.distractionSettingsEditable else { return }
        for preset in group.presets {
            setDistractionPreset(
                preset,
                enabled: enabled
            )
        }
    }

    func startDistractionBlock() {
        do {
            let request: IPCRequest
            if distractionDurationMinutes == 0 {
                request = IPCRequest(
                    command: .startDistractionBlock,
                    date: distractionCustomEnd
                )
            } else {
                request = IPCRequest(
                    command: .startDistractionBlock,
                    seconds: Double(distractionDurationMinutes * 60)
                )
            }
            let response = try UnixSocketClient.request(request)
            message = response.message
            if let status = response.status { self.status = status }
        } catch {
            message = String(describing: error)
        }
    }

    func startTest() {
        do {
            let response = try UnixSocketClient.request(IPCRequest(command: .startTest))
            message = response.message
            if let status = response.status { self.status = status }
        } catch { message = String(describing: error) }
    }

    func startPornBlocker() {
        do {
            let request: IPCRequest
            if pornDurationMinutes == 0 {
                request = IPCRequest(command: .startPornBlocker, date: pornCustomEnd)
            } else {
                request = IPCRequest(
                    command: .startPornBlocker,
                    seconds: Double(pornDurationMinutes * 60)
                )
            }
            let response = try UnixSocketClient.request(request)
            message = response.message
            if let status = response.status { self.status = status }
        } catch { message = String(describing: error) }
    }

    func lockSettings() {
        do {
            let request: IPCRequest
            if settingsGuardHours == 0 {
                request = IPCRequest(command: .lockSettings, date: settingsGuardCustomEnd)
            } else {
                request = IPCRequest(
                    command: .lockSettings,
                    seconds: Double(settingsGuardHours * 3600)
                )
            }
            let response = try UnixSocketClient.request(request)
            message = response.message
            if let status = response.status { self.status = status }
        } catch { message = String(describing: error) }
    }

    func clearAccountability() {
        _ = try? UnixSocketClient.request(IPCRequest(command: .clearAccountability))
        accountabilityAttemptedEvent = nil
        accountabilityWindow?.orderOut(nil)
        accountabilityWindow = nil
        refreshStatus()
    }

    func retryAccountabilityMessage() {
        accountabilityAttemptedEvent = nil
        sendAccountabilityIfNeeded()
        updateAccountabilityWindow()
    }

    func activateEmergencyNow() {
        do {
            let response = try UnixSocketClient.request(IPCRequest(command: .emergencyImmediate))
            message = response.message
            if let status = response.status { self.status = status }
            updateCountdownWindow()
            sendEmergencyAccessMessageIfNeeded()
        } catch { message = String(describing: error) }
    }

    private func handleSystemWake() {
        // The daemon intentionally waits a few seconds before re-enforcing sleep
        // after a wake so this prompt can be used without opening Terminal.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.refreshStatus()
            guard self.status.active,
                  self.status.emergencyImmediateAvailable else { return }
            self.confirmEmergencyNow()
        }
    }

    func confirmEmergencyNow() {
        guard !emergencyPromptVisible else { return }
        emergencyPromptVisible = true
        defer { emergencyPromptVisible = false }

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Use tonight-only sleep exception?"
        alert.informativeText = "This one-off exception exists only for tonight and disappears automatically tomorrow. It suspends only sleep enforcement until the current sleep window ends; your saved schedule and other blockers stay unchanged."
        alert.addButton(withTitle: "Use tonight-only exception")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            activateEmergencyNow()
        }
    }

    func beginEmergency() {
        do {
            let response = try UnixSocketClient.request(IPCRequest(command: .emergencyBegin, text: emergencyReason))
            emergencyChallenge = response.challenge ?? ""
            emergencyTyped = ""
            message = response.message
        } catch { message = String(describing: error) }
    }

    func submitEmergency() {
        do {
            let response = try UnixSocketClient.request(IPCRequest(command: .emergencySubmit, text: emergencyTyped))
            message = response.message
            if let status = response.status { self.status = status }
            emergencyChallenge = ""
            emergencyTyped = ""
            emergencyReason = ""
            updateCountdownWindow()
            sendEmergencyAccessMessageIfNeeded()
        } catch { message = String(describing: error) }
    }

    func activateEmergency() {
        do {
            let response = try UnixSocketClient.request(IPCRequest(command: .emergencyActivate))
            message = response.message
            if let status = response.status { self.status = status }
            updateCountdownWindow()
            sendEmergencyAccessMessageIfNeeded()
        } catch { message = String(describing: error) }
    }

    func menuText(now: Date = Date()) -> String {
        if status.active { return "Sleep locked" }
        if status.pornBlockerActive { return "Porn Blocker active" }
        if status.distractionBlockActive { return "Distractions blocked" }
        if let start = status.nextLockStart {
            let formatter = DateFormatter(); formatter.timeStyle = .short; formatter.dateStyle = .none
            return "Next sleep lock \(formatter.string(from: start))"
        }
        return config.enabled ? "Scheduled" : "Idle"
    }

    func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)

        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            return
        }

        let root = ContentView(state: self).preferredColorScheme(.dark)
        let hosting = NSHostingView(rootView: root)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "deadlock"
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        settingsWindow = window
    }

    private func updateCountdownWindow() {
        guard let start = status.nextLockStart else { closeCountdown(); return }
        let remaining = start.timeIntervalSinceNow
        if remaining > 0 && remaining <= 60 && status.emergencyOverrideUntil.map({ $0 > Date() }) != true {
            if countdownWindow == nil { showCountdown() }
        } else {
            closeCountdown()
        }
    }

    private func showCountdown() {
        guard let screen = NSScreen.main else { return }
        let view = CountdownView(state: self).preferredColorScheme(.dark)
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isOpaque = true
        window.backgroundColor = .black
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        countdownWindow = window
    }

    private func closeCountdown() {
        countdownWindow?.orderOut(nil)
        countdownWindow = nil
    }

    private func appleScriptQuoted(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    private func sendEmergencyAccessMessageIfNeeded() {
        guard let event = status.emergencyAccessTriggeredAt else { return }
        let recipient = pornSettings.accountabilityRecipient
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !recipient.isEmpty else { return }

        let key = "deadlock.last-emergency-access-message"
        let eventTime = event.timeIntervalSince1970
        let last = UserDefaults.standard.double(forKey: key)
        guard eventTime > last + 0.5 else { return }
        guard emergencyMessageAttemptedEvent != event else { return }

        // Mark before invoking Messages to avoid duplicate sends if the UI
        // refreshes while Automation permission is being resolved.
        emergencyMessageAttemptedEvent = event

        let safeRecipient = appleScriptQuoted(recipient)
        let untilText: String
        if let until = status.emergencyOverrideUntil {
            let formatter = DateFormatter()
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            untilText = formatter.string(from: until)
        } else {
            untilText = "its automatic expiry"
        }
        let sanitizedReason = status.emergencyAccessReason?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let reasonText = sanitizedReason.isEmpty
            ? ""
            : " Reason: " + String(sanitizedReason.prefix(240))
        let safeBody = appleScriptQuoted(
            "Deadlock emergency sleep access was activated on my Mac. "
            + "Sleep enforcement is temporarily suspended until \(untilText) "
            + "and will resume automatically. My other blockers remain active."
            + reasonText
        )
        let source = "tell application \"Messages\" to send \"\(safeBody)\" to buddy \"\(safeRecipient)\" of (first service whose service type = iMessage)"
        var errorInfo: NSDictionary?
        if let script = NSAppleScript(source: source) {
            _ = script.executeAndReturnError(&errorInfo)
        }
        if let errorInfo {
            message = "Emergency access started, but the friend iMessage could not be sent. Check the recipient and allow deadlock to control Messages in Privacy & Security → Automation. (\(errorInfo))"
        } else {
            UserDefaults.standard.set(eventTime, forKey: key)
        }
    }

    private func sendAccountabilityIfNeeded() {
        guard status.accountabilityEnabled,
              let event = status.accountabilityTriggeredAt else { return }
        let recipient = pornSettings.accountabilityRecipient.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !recipient.isEmpty else { return }

        let key = "deadlock.last-accountability-event"
        let eventTime = event.timeIntervalSince1970
        let last = UserDefaults.standard.double(forKey: key)
        guard eventTime > last + 0.5 else { return }
        guard accountabilityAttemptedEvent != event else { return }

        // Mark before invoking Messages so a 30-second status refresh cannot
        // cause a burst of repeated Automation attempts. Retry is explicit.
        accountabilityAttemptedEvent = event

        let safeRecipient = appleScriptQuoted(recipient)
        let safeBody = appleScriptQuoted("I tried to access blocked porn content on my Mac. Deadlock blocked it.")
        let source = "tell application \"Messages\" to send \"\(safeBody)\" to buddy \"\(safeRecipient)\" of (first service whose service type = iMessage)"
        var errorInfo: NSDictionary?
        if let script = NSAppleScript(source: source) {
            _ = script.executeAndReturnError(&errorInfo)
        }
        if let errorInfo {
            message = "Could not send accountability iMessage. Check the recipient and allow deadlock to control Messages in Privacy & Security → Automation. (\(errorInfo))"
        } else {
            UserDefaults.standard.set(eventTime, forKey: key)
        }
    }

    private func updateAccountabilityWindow() {
        guard status.accountabilityTriggeredAt != nil else {
            accountabilityWindow?.orderOut(nil)
            accountabilityWindow = nil
            return
        }

        sendAccountabilityIfNeeded()

        if !pornSettings.motivationalOverlayEnabled {
            clearAccountability()
            return
        }

        guard accountabilityWindow == nil, let screen = NSScreen.main else { return }
        let lines = [
            "You set the block for a reason. Keep the decision you made earlier.",
            "The urge is temporary. Your plan is still the plan.",
            "Close this, switch context, and do the next useful thing.",
            "Protect the next ten minutes. The rest gets easier from there.",
            "Don't negotiate with the block while the urge is loud."
        ]
        let motivation = lines.randomElement() ?? lines[0]
        let sendError: String? = message.hasPrefix("Could not send accountability iMessage") ? message : nil
        let view = AccountabilityView(
            reason: status.accountabilityReason ?? "blocked content",
            motivation: motivation,
            sendError: sendError,
            onRetry: { [weak self] in self?.retryAccountabilityMessage() },
            onBack: { [weak self] in self?.clearAccountability() }
        ).preferredColorScheme(.dark)

        let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isOpaque = true
        window.backgroundColor = .black
        window.contentView = NSHostingView(rootView: view)
        window.makeKeyAndOrderFront(nil)
        accountabilityWindow = window
    }
}

enum MenuBarIcon {
    static let image: NSImage = {
        if let url = Bundle.main.url(
            forResource: "deadlock-menubar",
            withExtension: "png"
        ), let image = NSImage(contentsOf: url) {
            image.isTemplate = true
            image.size = NSSize(width: 18, height: 18)
            return image
        }

        let fallback = NSImage(
            systemSymbolName: "lock.shield.fill",
            accessibilityDescription: "deadlock"
        ) ?? NSImage()
        fallback.isTemplate = true
        return fallback
    }()
}

struct CountdownView: View {
    @ObservedObject var state: AppState

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 0.25)) { context in
            let now = context.date
            let target = state.status.nextLockStart ?? now
            let seconds = max(0, Int(ceil(target.timeIntervalSince(now))))

            ZStack {
                Color.black.ignoresSafeArea()
                VStack(spacing: 18) {
                    Image(systemName: "lock.shield.fill").font(.system(size: 44))
                    Text("deadlock begins in").font(.system(size: 28, weight: .medium))
                    Text("\(seconds)")
                        .font(.system(size: 120, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("Save your work now.").font(.title2).foregroundStyle(.secondary)
                }
                .foregroundStyle(.white)
            }
        }
    }
}

struct RemainingTimeView: View {
    let until: Date
    var body: some View {
        TimelineView(.periodic(from: Date(), by: 1)) { context in
            let seconds = max(0, Int(until.timeIntervalSince(context.date)))
            let days = seconds / 86400
            let hours = (seconds % 86400) / 3600
            let minutes = (seconds % 3600) / 60
            let secs = seconds % 60
            if days > 0 {
                Text(String(format: "%dd %02d:%02d:%02d remaining", days, hours, minutes, secs)).monospacedDigit()
            } else {
                Text(String(format: "%02d:%02d:%02d remaining", hours, minutes, secs)).monospacedDigit()
            }
        }
    }
}

struct AccountabilityView: View {
    let reason: String
    let motivation: String
    let sendError: String?
    let onRetry: () -> Void
    let onBack: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 22) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 64, weight: .semibold))
                Text("Blocked")
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                Text(motivation)
                    .font(.title2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 640)
                Text("Detected: \(reason)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let sendError {
                    Text(sendError)
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 680)
                    Button("Retry accountability message") { onRetry() }
                } else {
                    Text("If accountability is configured, Deadlock attempted one rate-limited accountability message for this event.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 620)
                }
                Button("Go back") { onBack() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
            .padding(48)
            .foregroundStyle(.white)
        }
    }
}

struct ScheduleRow: View {
    @Binding var day: DaySchedule
    var disabled: Bool
    let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    private var startDate: Binding<Date> {
        Binding(
            get: { Calendar.current.date(from: DateComponents(hour: day.startMinutes / 60, minute: day.startMinutes % 60)) ?? Date() },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                day.startMinutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }
        )
    }

    private var endDate: Binding<Date> {
        Binding(
            get: { Calendar.current.date(from: DateComponents(hour: day.endMinutes / 60, minute: day.endMinutes % 60)) ?? Date() },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                day.endMinutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }
        )
    }

    var body: some View {
        HStack {
            Toggle(names[max(0, min(6, day.weekday - 1))], isOn: $day.enabled)
                .frame(width: 82, alignment: .leading)
            DatePicker("Start", selection: startDate, displayedComponents: .hourAndMinute).labelsHidden()
            Text("→").foregroundStyle(.secondary)
            DatePicker("End", selection: endDate, displayedComponents: .hourAndMinute).labelsHidden()
        }
        .disabled(disabled)
    }
}

struct ContentView: View {
    @ObservedObject var state: AppState
    private let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Image(systemName: "lock.shield.fill").font(.system(size: 32, weight: .semibold))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("deadlock").font(.largeTitle.bold())
                        Text(state.menuText()).foregroundStyle(state.status.active ? .red : .secondary)
                    }
                    Spacer()
                    Circle().frame(width: 10, height: 10).foregroundStyle(state.status.daemonRunning ? .green : .red)
                }

                GroupBox("Sleep Lock") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Enable sleep lock", isOn: $state.config.enabled)
                            .disabled(state.status.configChangesBlocked)
                        ForEach($state.config.days) { $day in
                            ScheduleRow(day: $day, disabled: state.status.configChangesBlocked)
                        }
                        HStack {
                            Button("Save sleep schedule") { state.saveSleepSchedule() }
                                .disabled(state.status.configChangesBlocked)
                            Button("Run 2-minute test") { state.startTest() }
                            Spacer()
                        }

                        if state.status.active {
                            Divider()
                            HStack {
                                Label("Sleep lock is enforcing now", systemImage: "moon.zzz.fill")
                                    .font(.headline)
                                Spacer()
                                Label("Emergency grace: 5 min max", systemImage: "hourglass")
                                    .font(.caption.weight(.semibold))
                            }
                            Text("There is no instant or full-window unlock. A deliberate emergency may grant one 5-minute grace period for this sleep window from the Emergency section below.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }.padding(4)
                }


                GroupBox("Bed Guard — AirPods") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(state.bedGuardSensor.message)
                                    .font(.headline)
                                Text(
                                    state.bedGuardSettings.poses.isEmpty
                                        ? "No bed positions recorded yet."
                                        : "\(state.bedGuardSettings.poses.count) bed position\(state.bedGuardSettings.poses.count == 1 ? "" : "s") recorded."
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Circle()
                                .frame(width: 9, height: 9)
                                .foregroundStyle(
                                    state.bedGuardSettings.enabled
                                        && state.bedGuardSensor.monitoring
                                        ? .orange
                                        : .secondary
                                )
                        }

                        Toggle(
                            "Enable Bed Guard",
                            isOn: Binding(
                                get: { state.bedGuardSettings.enabled },
                                set: { state.setBedGuardEnabled($0) }
                            )
                        )
                        .disabled(
                            state.status.configChangesBlocked
                                || state.bedGuardSettings.poses.isEmpty
                        )

                        if state.bedGuardSensor.calibrating {
                            ProgressView(
                                value: state.bedGuardSensor.calibrationProgress
                            )
                            Text("Stay in the position you normally use the laptop in bed.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if state.bedGuardSensor.heldSeconds > 0 {
                            ProgressView(
                                value: min(
                                    1,
                                    state.bedGuardSensor.heldSeconds
                                        / state.bedGuardSettings.sustainSeconds
                                )
                            )
                            Text(
                                "Bed-like posture held for \(Int(state.bedGuardSensor.heldSeconds))s / \(Int(state.bedGuardSettings.sustainSeconds))s."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }

                        HStack {
                            Button("Record current bed posture (5 sec)") {
                                state.recordBedGuardPose()
                            }
                            .disabled(
                                state.status.configChangesBlocked
                                    || state.bedGuardSensor.calibrating
                            )

                            Button("Clear poses") {
                                state.clearBedGuardPoses()
                            }
                            .disabled(
                                state.status.configChangesBlocked
                                    || state.bedGuardSettings.poses.isEmpty
                            )
                        }

                        Text("Wear motion-capable AirPods, get into a normal laptop-in-bed position, then record it. Add separate back/left/right positions if needed. If a saved posture matches for 20 seconds, the root daemon sleeps the Mac. Waking it without getting up will let Bed Guard trigger again.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text("Motion is processed locally. Deadlock does not use the microphone or camera. After calibration, Settings Guard can stop you from disabling Bed Guard impulsively.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(4)
                }

                GroupBox("Distractions") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: "eye.slash")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(
                                    state.status.distractionBlockActive
                                        ? "Blocking distracting websites"
                                        : "Distraction blocker ready"
                                )
                                .font(.headline)

                                if let until = state.status.distractionBlockUntil,
                                   until > Date() {
                                    RemainingTimeView(until: until)
                                } else if let end = state.status.distractionScheduledEnd,
                                          end > Date() {
                                    Text(
                                        "Scheduled block ends \(end.formatted(date: .omitted, time: .shortened))"
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Circle()
                                .frame(width: 9, height: 9)
                                .foregroundStyle(
                                    state.status.distractionBlockActive
                                        ? .orange
                                        : .secondary
                                )
                        }

                        Label("Discord is always allowed", systemImage: "checkmark.shield")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Label("Instagram is permanently blocked", systemImage: "lock.shield.fill")
                            .font(.caption.weight(.semibold))
                        Text("Temporary Instagram exceptions are disabled. This cannot be negotiated through the emergency path.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        HStack {
                            Picker(
                                "Block for",
                                selection: $state.distractionDurationMinutes
                            ) {
                                Text("5 min").tag(5)
                                Text("15 min").tag(15)
                                Text("30 min").tag(30)
                                Text("1 hour").tag(60)
                                Text("2 hours").tag(120)
                                Text("4 hours").tag(240)
                                Text("8 hours").tag(480)
                                Text("1 day").tag(1440)
                                Text("7 days").tag(10080)
                                Text("Custom…").tag(0)
                            }
                            .frame(width: 190)

                            Button("Block now") {
                                state.startDistractionBlock()
                            }
                        }

                        if state.distractionDurationMinutes == 0 {
                            DatePicker(
                                "Custom end",
                                selection: $state.distractionCustomEnd,
                                in: Date().addingTimeInterval(5 * 60) ... Date().addingTimeInterval(365 * 24 * 3600)
                            )
                        }

                        Divider()

                        Toggle(
                            "Use a weekly distraction schedule",
                            isOn: $state.distractionSettings.scheduleEnabled
                        )
                        .disabled(!state.status.distractionSettingsEditable)

                        ForEach($state.distractionSettings.days) { $day in
                            ScheduleRow(
                                day: $day,
                                disabled: !state.status.distractionSettingsEditable
                            )
                        }

                        Text("Blocked websites")
                            .font(.headline)

                        Label(
                            "Maintained social/distraction list included",
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                        .font(.caption.weight(.semibold))

                        Text(
                            "Deadlock automatically refreshes StevenBlack's social-only list. "
                            + "Imported entries cannot override protected communication exceptions "
                            + "such as Discord, Instagram, Slack, Teams, Zoom or Google Meet. "
                            + "Your explicit local rules still decide Instagram and YouTube."
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                        DistractionPresetPicker(state: state)

                        Text("Custom domains")
                            .font(.subheadline.weight(.medium))

                        TextField(
                            "instagram.com, tiktok.com, reddit.com…",
                            text: Binding(
                                get: {
                                    state.distractionSettings.blockedDomains
                                        .joined(separator: ", ")
                                },
                                set: { value in
                                    state.distractionSettings.blockedDomains =
                                        value
                                        .split(separator: ",")
                                        .map {
                                            $0.trimmingCharacters(
                                                in: .whitespacesAndNewlines
                                            )
                                        }
                                        .filter { !$0.isEmpty }
                                }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                        .disabled(!state.status.distractionSettingsEditable)

                        Text(
                            "Presets only edit the same website list below, "
                            + "so you can mix presets with your own domains. "
                            + "YouTube stays available to IINA while Deadlock "
                            + "blocks it in supported browsers. Once a block "
                            + "starts, these settings cannot be weakened until "
                            + "it ends."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        Button("Save distraction settings") {
                            state.saveDistractionSettings()
                        }
                        .disabled(!state.status.distractionSettingsEditable)
                    }
                    .padding(4)
                }

                GroupBox("Permanent adult-content protection") {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Always on", systemImage: "lock.fill")
                            .font(.headline)
                        Text("Adult websites are blocked 24/7. Sleep emergency access, distraction exceptions and schedule changes do not disable this protection.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Deadlock refreshes the maintained adult-domain list every 6 hours and keeps the last valid copy if the network or upstream source is unavailable. DeviantArt is also hard-blocked separately.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if !state.status.webProtectionHealthy {
                            Label("Web protection needs repair", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            if let error = state.status.webProtectionLastError {
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Divider()

                        Text("Accountability friend")
                            .font(.headline)
                        HStack {
                            TextField(
                                "Friend iMessage phone number or email",
                                text: $state.pornSettings.accountabilityRecipient
                            )
                            .textFieldStyle(.roundedBorder)
                            Button("Save friend") {
                                state.savePornSettings()
                            }
                        }

                        Text("The friend address can still be corrected without weakening permanent blocking. Deadlock can use it for emergency sleep-access alerts and configured adult-content accountability events.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }.padding(4)
                }

                GroupBox("Settings Guard") {
                    VStack(alignment: .leading, spacing: 10) {
                        if let until = state.status.settingsLockedUntil, until > Date() {
                            Text("Settings locked until \(until.formatted(date: .abbreviated, time: .shortened))")
                            RemainingTimeView(until: until)
                        } else {
                            HStack {
                                Picker("Lock settings for", selection: $state.settingsGuardHours) {
                                    Text("1 hour").tag(1)
                                    Text("4 hours").tag(4)
                                    Text("1 day").tag(24)
                                    Text("3 days").tag(72)
                                    Text("1 week").tag(168)
                                    Text("2 weeks").tag(336)
                                    Text("30 days").tag(720)
                                    Text("90 days").tag(2160)
                                    Text("Custom…").tag(0)
                                }
                                .frame(width: 210)
                                Button("Lock settings") { state.lockSettings() }
                            }
                            if state.settingsGuardHours == 0 {
                                DatePicker(
                                    "Custom unlock",
                                    selection: $state.settingsGuardCustomEnd,
                                    in: Date().addingTimeInterval(3600)...Date().addingTimeInterval(365 * 24 * 3600)
                                )
                            }
                        }
                    }.padding(4)
                }

                GroupBox("Emergency 5-minute grace") {
                    VStack(alignment: .leading, spacing: 10) {
                        if let until = state.status.emergencyOverrideUntil,
                           until > Date() {
                            Label("5-minute emergency grace is active", systemImage: "exclamationmark.triangle.fill")
                                .font(.headline)
                            RemainingTimeView(until: until)
                            Text("Sleep enforcement resumes automatically when this expires. It cannot be extended during the same sleep window.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("There is no instant emergency unlock and no full-window override. The only exception is one 5-minute grace period per active sleep window.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Divider()

                        Text("Strict emergency check")
                            .font(.headline)
                        Text("Explain the immediate concrete consequence of waiting in at least 160 characters and 25 words. After validation, type FIVE MINUTES ONLY exactly. If accepted, Deadlock grants at most five minutes once for the current sleep window.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        TextEditor(text: $state.emergencyReason)
                            .frame(height: 100)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.secondary.opacity(0.35))
                            )

                        Text("\(state.emergencyReason.trimmingCharacters(in: .whitespacesAndNewlines).count) / 160 minimum characters")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        Button("Validate emergency reason") {
                            state.beginEmergency()
                        }

                        if !state.emergencyChallenge.isEmpty {
                            Text("Type this exactly to confirm:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(state.emergencyChallenge)
                                .font(.system(.body, design: .monospaced).weight(.semibold))
                                .textSelection(.enabled)
                            TextField("Confirmation phrase", text: $state.emergencyTyped)
                                .textFieldStyle(.roundedBorder)
                            Button("Use my one 5-minute grace") {
                                state.submitEmergency()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(.top, 8)
                }

                if let activation = state.status.pendingConfigActivation {
                    Text("A loosening sleep change is queued for \(activation.formatted(date: .abbreviated, time: .shortened)).")
                        .font(.callout).foregroundStyle(.orange)
                }
                if !state.message.isEmpty {
                    Text(state.message).font(.callout).foregroundStyle(.secondary)
                }

                HStack {
                    Spacer()
                    Button("Refresh") { state.refreshAll() }
                }
            }
            .padding(24)
        }
        .frame(minWidth: 660, minHeight: 760)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.dark)
    }
}


enum MenuBarSingleton {
    private static var lockDescriptor: Int32 = -1

    static func acquire() -> Bool {
        guard lockDescriptor < 0 else {
            return true
        }

        let path =
            "/tmp/deadlock-menubar-\(getuid()).lock"
        let descriptor = Darwin.open(
            path,
            O_CREAT
                | O_RDWR
                | O_EXLOCK
                | O_NONBLOCK,
            S_IRUSR | S_IWUSR
        )

        guard descriptor >= 0 else {
            if errno == EWOULDBLOCK
                || errno == EAGAIN {
                return false
            }

            // Failing for an unrelated filesystem reason is unusual. Prefer
            // one usable UI over making Deadlock disappear entirely.
            return true
        }

        lockDescriptor = descriptor
        return true
    }
}

struct BedtimeLockApp: App {
    private let state = AppState()

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            Text(state.menuText())
                .onAppear {
                    state.refreshStatus()
                }

            if state.status.active {
                Label("Sleep lock active · emergency grace is 5 min max", systemImage: "moon.zzz.fill")
            }
            if state.status.pornBlockerActive {
                Label("Porn Blocker active", systemImage: "shield.fill")
            }
            if state.status.distractionBlockActive {
                Label("Distractions blocked", systemImage: "eye.slash.fill")
            }
            if state.bedGuardSettings.enabled {
                Label("Bed Guard armed", systemImage: "airpodspro")
            }

            Divider()

            Button("Open deadlock") {
                state.showMainWindow()
            }

            Button("Refresh") {
                state.refreshAll()
            }
        } label: {
            Image(nsImage: MenuBarIcon.image)
                .accessibilityLabel("deadlock")
        }
    }
}

func runCLI() -> Never {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: "--ipc"), args.count > index + 1 else {
        fputs("usage: deadlock --ipc <status|focus-start|distraction-start|emergency-now|uninstall-request|uninstall-status> [args]\n", stderr)
        exit(2)
    }

    let command = args[index + 1]

    do {
        let request: IPCRequest

        switch command {
        case "status":
            request = IPCRequest(command: .getStatus)

        case "focus-start", "distraction-start":
            guard args.count > index + 2,
                  let seconds = Double(args[index + 2]),
                  seconds.isFinite,
                  seconds > 0
            else {
                fputs("focus-start requires a positive duration in seconds\n", stderr)
                exit(2)
            }

            request = IPCRequest(
                command: .startDistractionBlock,
                seconds: seconds
            )

        case "uninstall-request":
            request = IPCRequest(command: .uninstallRequest)

        case "uninstall-status":
            request = IPCRequest(command: .uninstallStatus)

        default:
            fputs("unknown ipc command\n", stderr)
            exit(2)
        }

        let response = try UnixSocketClient.request(request)
        print(response.message)
        exit(response.ok ? 0 : 1)
    } catch {
        fputs("\(error)\n", stderr)
        exit(1)
    }
}

if CommandLine.arguments.contains("--ipc") {
    runCLI()
} else {
    guard MenuBarSingleton.acquire() else {
        // Another Deadlock UI instance already owns the menu-bar slot.
        // Exit successfully so launchd does not treat this as a crash.
        exit(0)
    }
    BedtimeLockApp.main()
}
