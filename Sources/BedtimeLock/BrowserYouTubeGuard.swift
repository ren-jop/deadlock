import Foundation
import AppKit
import ApplicationServices

/// User-session YouTube enforcement.
///
/// The privileged daemon deliberately leaves YouTube DNS untouched so IINA and
/// yt-dlp can resolve it normally. Browser inspection belongs here instead of
/// in the root LaunchDaemon because macOS does not reliably expose another
/// user's browser UI / Apple Events to a system daemon.
@MainActor
final class BrowserYouTubeGuard {
    private enum BrowserFlavor {
        case safari
        case chromium
    }

    private let shouldBlock: () -> Bool
    private let onDiagnostic: (String) -> Void
    private var timer: Timer?
    private var lastClosedAt = Date.distantPast
    private var lastAutomationFailureBundle: String?
    private var didPromptForAccessibility = false

    init(
        shouldBlock: @escaping () -> Bool,
        onDiagnostic: @escaping (String) -> Void
    ) {
        self.shouldBlock = shouldBlock
        self.onDiagnostic = onDiagnostic
    }

    func start() {
        guard timer == nil else { return }

        let timer = Timer(timeInterval: 0.75, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.evaluateFrontmostApplication()
            }
        }
        timer.tolerance = 0.10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        evaluateFrontmostApplication()
    }

    deinit {
        timer?.invalidate()
    }

    private func evaluateFrontmostApplication() {
        guard shouldBlock(),
              Date().timeIntervalSince(lastClosedAt) > 0.35,
              let app = NSWorkspace.shared.frontmostApplication
        else {
            return
        }

        let bundle = (app.bundleIdentifier ?? "").lowercased()
        guard !bundle.contains("iina") else { return }

        if isOfficialYouTubeApp(app) {
            if !app.terminate() {
                _ = app.forceTerminate()
            }
            lastClosedAt = Date()
            onDiagnostic("Blocked the YouTube app. IINA remains available.")
            return
        }

        guard let originalBundle = app.bundleIdentifier,
              let flavor = browserFlavor(for: originalBundle)
        else {
            return
        }

        if let url = activeURL(
            bundleIdentifier: originalBundle,
            flavor: flavor
        ) {
            lastAutomationFailureBundle = nil
            guard isYouTubeURL(url) else { return }

            if closeActiveTab(
                bundleIdentifier: originalBundle,
                flavor: flavor
            ) {
                lastClosedAt = Date()
                onDiagnostic(
                    "Closed the blocked YouTube tab. IINA remains available."
                )
                return
            }

            if flavor == .safari,
               closeSafariTabWithAccessibility(app: app) {
                lastClosedAt = Date()
                onDiagnostic(
                    "Closed the blocked Safari YouTube tab. IINA remains available."
                )
                return
            }

            reportAutomationFailureOnce(
                app: app,
                bundleIdentifier: originalBundle
            )
            return
        }

        if flavor == .safari {
            if safariWindowLooksLikeYouTube(app: app) {
                if closeSafariTabWithAccessibility(app: app) {
                    lastClosedAt = Date()
                    onDiagnostic(
                        "Closed the blocked Safari YouTube tab. IINA remains available."
                    )
                    return
                }
            }

            requestAccessibilityForSafariIfNeeded()
            return
        }

        reportAutomationFailureOnce(
            app: app,
            bundleIdentifier: originalBundle
        )
    }

    private func browserFlavor(for bundleIdentifier: String) -> BrowserFlavor? {
        switch bundleIdentifier {
        case "com.apple.Safari":
            return .safari

        case "com.google.Chrome",
             "com.google.Chrome.canary",
             "com.brave.Browser",
             "com.microsoft.edgemac",
             "company.thebrowser.Browser",
             "com.vivaldi.Vivaldi",
             "com.operasoftware.Opera",
             "net.imput.helium":
            return .chromium

        default:
            return nil
        }
    }

    private func activeURL(
        bundleIdentifier: String,
        flavor: BrowserFlavor
    ) -> String? {
        let source: String
        switch flavor {
        case .safari:
            source = """
            tell application id "\(bundleIdentifier)"
                if (count of windows) = 0 then return ""
                return URL of current tab of front window
            end tell
            """

        case .chromium:
            source = """
            tell application id "\(bundleIdentifier)"
                if (count of windows) = 0 then return ""
                return URL of active tab of front window
            end tell
            """
        }

        return executeAppleScript(source)
    }

    private func closeActiveTab(
        bundleIdentifier: String,
        flavor: BrowserFlavor
    ) -> Bool {
        let source: String
        switch flavor {
        case .safari:
            source = """
            tell application id "\(bundleIdentifier)"
                if (count of windows) = 0 then return "no-window"
                close current tab of front window
                return "closed"
            end tell
            """

        case .chromium:
            source = """
            tell application id "\(bundleIdentifier)"
                if (count of windows) = 0 then return "no-window"
                close active tab of front window
                return "closed"
            end tell
            """
        }

        return executeAppleScript(source) == "closed"
    }

    private func executeAppleScript(_ source: String) -> String? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        guard errorInfo == nil else { return nil }
        return result.stringValue
    }

    private func safariWindowLooksLikeYouTube(
        app: NSRunningApplication
    ) -> Bool {
        guard AXIsProcessTrusted() else { return false }

        let application = AXUIElementCreateApplication(
            app.processIdentifier
        )
        var focusedWindowRef: CFTypeRef?

        guard AXUIElementCopyAttributeValue(
            application,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindowRef
        ) == .success,
              let focusedWindowRef
        else {
            return false
        }

        let focusedWindow = focusedWindowRef as! AXUIElement
        var titleRef: CFTypeRef?

        guard AXUIElementCopyAttributeValue(
            focusedWindow,
            kAXTitleAttribute as CFString,
            &titleRef
        ) == .success,
              let title = titleRef as? String
        else {
            return false
        }

        let lower = title.lowercased()
        return lower == "youtube"
            || lower.contains(" - youtube")
            || lower.contains(" — youtube")
            || lower.hasSuffix("youtube")
    }

    private func closeSafariTabWithAccessibility(
        app: NSRunningApplication
    ) -> Bool {
        guard AXIsProcessTrusted(),
              app.bundleIdentifier == "com.apple.Safari",
              NSWorkspace.shared.frontmostApplication?
                .processIdentifier == app.processIdentifier
        else {
            requestAccessibilityForSafariIfNeeded()
            return false
        }

        guard let source = CGEventSource(
            stateID: .hidSystemState
        ),
              let keyDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: 13,
                keyDown: true
              ),
              let keyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: 13,
                keyDown: false
              )
        else {
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    private func requestAccessibilityForSafariIfNeeded() {
        guard !AXIsProcessTrusted() else { return }

        if !didPromptForAccessibility {
            didPromptForAccessibility = true
            let promptKey =
                kAXTrustedCheckOptionPrompt
                    .takeUnretainedValue() as String
            let options = [
                promptKey: true
            ] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }

        onDiagnostic(
            "Safari needs one-time Accessibility access so deadlock can close only blocked YouTube tabs. Enable deadlock in System Settings → Privacy & Security → Accessibility. IINA remains untouched."
        )
    }

    private func isYouTubeURL(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        if let host = URL(string: trimmed)?.host?.lowercased() {
            return isYouTubeHost(host)
        }

        let lower = trimmed.lowercased()
        return lower.contains("youtube.com")
            || lower.contains("youtu.be")
            || lower.contains("youtube-nocookie.com")
    }

    private func isYouTubeHost(_ host: String) -> Bool {
        let normalized = host.lowercased()
        return normalized == "youtube.com"
            || normalized.hasSuffix(".youtube.com")
            || normalized == "youtu.be"
            || normalized.hasSuffix(".youtu.be")
            || normalized == "youtube-nocookie.com"
            || normalized.hasSuffix(".youtube-nocookie.com")
    }

    private func isOfficialYouTubeApp(_ app: NSRunningApplication) -> Bool {
        let bundle = (app.bundleIdentifier ?? "").lowercased()
        if bundle.contains("iina") { return false }

        if bundle == "com.google.ios.youtube"
            || bundle == "com.google.youtube" {
            return true
        }

        return app.localizedName?.lowercased() == "youtube"
    }

    private func reportAutomationFailureOnce(
        app: NSRunningApplication,
        bundleIdentifier: String
    ) {
        guard lastAutomationFailureBundle != bundleIdentifier else { return }
        lastAutomationFailureBundle = bundleIdentifier
        let name = app.localizedName ?? "your browser"
        onDiagnostic(
            "To block YouTube only in \(name), allow deadlock to control \(name) in System Settings → Privacy & Security → Automation. IINA does not need this permission."
        )
    }
}
