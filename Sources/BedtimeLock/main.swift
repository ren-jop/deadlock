import SwiftUI
import AppKit
import DeadlockShared
import Combine

@MainActor
final class AppState: ObservableObject {
    @Published var config: LockConfig = .defaultConfig
    @Published var pornSettings: PornSettings = .defaultSettings
    @Published var distractionSettings: DistractionSettings = .defaultSettings
    @Published var status = DaemonStatus(daemonRunning: false)
    @Published var message = ""
    @Published var emergencyChallenge = ""
    @Published var emergencyTyped = ""
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

    init() {
        scheduleRefresh()

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
            if let status = response.status { self.status = status }
            message = ""
            updateCountdownWindow()
            updateAccountabilityWindow()
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
            updateCountdownWindow()
            updateAccountabilityWindow()
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

    func beginEmergency() {
        do {
            let response = try UnixSocketClient.request(IPCRequest(command: .emergencyBegin))
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
        } catch { message = String(describing: error) }
    }

    func activateEmergency() {
        do {
            let response = try UnixSocketClient.request(IPCRequest(command: .emergencyActivate))
            message = response.message
            if let status = response.status { self.status = status }
            updateCountdownWindow()
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
                    }.padding(4)
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
                            "This is the Cold Turkey-style website layer. "
                            + "YouTube is not blocked by default. "
                            + "Once a distraction block starts, these settings "
                            + "cannot be weakened until it ends."
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

                GroupBox("Porn Blocker") {
                    VStack(alignment: .leading, spacing: 12) {
                        if state.status.pornBlockerActive {
                            Label("Protection active", systemImage: "lock.fill").font(.headline)
                            if let manual = state.status.pornBlockerUntil, manual > Date() {
                                Text("Manual lock ends \(manual.formatted(date: .abbreviated, time: .shortened))")
                                RemainingTimeView(until: manual)
                            }
                            if let scheduledEnd = state.status.pornScheduledEnd, scheduledEnd > Date() {
                                Text("Mandatory schedule ends \(scheduledEnd.formatted(date: .omitted, time: .shortened))")
                            }
                            Text("It cannot be disabled or weakened while this window is active.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            if let next = state.status.pornScheduleNextStart {
                                Text("Next mandatory window: \(next.formatted(date: .abbreviated, time: .shortened))")
                                    .foregroundStyle(.secondary)
                            }
                            if !state.status.webProtectionHealthy {
                                Label("Web protection needs repair", systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                if let error = state.status.webProtectionLastError {
                                    Text(error).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            HStack {
                                Picker("Lock for", selection: $state.pornDurationMinutes) {
                                    Text("15 min").tag(15)
                                    Text("30 min").tag(30)
                                    Text("1 hour").tag(60)
                                    Text("2 hours").tag(120)
                                    Text("4 hours").tag(240)
                                    Text("8 hours").tag(480)
                                    Text("12 hours").tag(720)
                                    Text("1 day").tag(1440)
                                    Text("3 days").tag(4320)
                                    Text("7 days").tag(10080)
                                    Text("30 days").tag(43200)
                                    Text("Custom…").tag(0)
                                }
                                .frame(width: 190)
                                Button("Lock now") { state.startPornBlocker() }
                            }
                            if state.pornDurationMinutes == 0 {
                                DatePicker(
                                    "Custom end",
                                    selection: $state.pornCustomEnd,
                                    in: Date().addingTimeInterval(15 * 60)...Date().addingTimeInterval(365 * 24 * 3600)
                                )
                            }
                        }

                        Divider()
                        Text("Mandatory hours").font(.headline)
                        Toggle("Always enforce scheduled windows", isOn: $state.pornSettings.scheduleEnabled)
                            .disabled(!state.status.pornSettingsEditableToday)
                        ForEach($state.pornSettings.days) { $day in
                            ScheduleRow(day: $day, disabled: !state.status.pornSettingsEditableToday)
                        }

                        HStack {
                            Text("Settings edit day")
                            Picker("", selection: $state.pornSettings.editWeekday) {
                                ForEach(1...7, id: \.self) { day in Text(weekdays[day - 1]).tag(day) }
                            }
                            .labelsHidden()
                            .frame(width: 150)
                            .disabled(!state.status.pornSettingsEditableToday)
                            Spacer()
                            if !state.status.pornSettingsEditableToday {
                                Text("Locked today").font(.caption).foregroundStyle(.secondary)
                            }
                        }

                        Divider()
                        Toggle("Friend accountability", isOn: $state.pornSettings.accountabilityEnabled)
                            .disabled(!state.status.pornSettingsEditableToday)
                        TextField("Friend iMessage phone number or email", text: $state.pornSettings.accountabilityRecipient)
                            .textFieldStyle(.roundedBorder)
                            .disabled(!state.status.pornSettingsEditableToday)
                        Toggle("Show dark motivational interruption", isOn: $state.pornSettings.motivationalOverlayEnabled)
                            .disabled(!state.status.pornSettingsEditableToday)

                        Text("During protection, matching adult URLs/text closes the app. If a friend is configured, Deadlock automatically sends one accountability iMessage per 10-minute period to avoid duplicate spam.")
                            .font(.caption).foregroundStyle(.secondary)

                        Button("Save Porn Blocker settings") { state.savePornSettings() }
                            .disabled(!state.status.pornSettingsEditableToday)
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

                DisclosureGroup("Emergency sleep override") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("A real verified $1 payment would require an external payment processor/server, so this build uses high-friction accountability instead: it notifies your configured friend, requires a 200-character challenge, then a 30-minute wait.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Start emergency process") { state.beginEmergency() }
                        if !state.emergencyChallenge.isEmpty {
                            Text(state.emergencyChallenge)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                            TextEditor(text: $state.emergencyTyped)
                                .font(.system(.caption, design: .monospaced))
                                .frame(height: 90)
                            Button("Submit exact text") { state.submitEmergency() }
                        }
                        if let ready = state.status.emergencyReadyAt {
                            Text("Available at \(ready.formatted(date: .omitted, time: .standard))")
                            Button("Activate 2-hour sleep override") { state.activateEmergency() }
                                .disabled(ready > Date())
                        }
                    }.padding(.top, 8)
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
                Label("Sleep lock active", systemImage: "moon.zzz.fill")
            }
            if state.status.pornBlockerActive {
                Label("Porn Blocker active", systemImage: "shield.fill")
            }
            if state.status.distractionBlockActive {
                Label("Distractions blocked", systemImage: "eye.slash.fill")
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
        fputs("usage: deadlock --ipc <status|focus-start|distraction-start|uninstall-request|uninstall-status> [seconds]\n", stderr)
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
    BedtimeLockApp.main()
}
