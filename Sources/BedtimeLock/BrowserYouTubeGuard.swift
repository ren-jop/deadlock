import Foundation
import AppKit
import ApplicationServices

/// User-session YouTube enforcement.
///
/// YouTube intentionally stays out of DNS blocking so IINA/yt-dlp keep normal
/// network access. Browsers are handled in the logged-in session instead:
/// native browser policy where available, AppleScript where exposed, and a
/// generic Accessibility fallback for browsers such as Zen and Firefox forks.
@MainActor
final class BrowserYouTubeGuard {
    private let shouldBlock: () -> Bool
    private let onDiagnostic: (String) -> Void

    private var timer: Timer?
    private var lastClosedAt = Date.distantPast
    private var didPromptForAccessibility = false
    private var lastAccessibilityDiagnosticApp: String?

    init(
        shouldBlock: @escaping () -> Bool,
        onDiagnostic: @escaping (String) -> Void
    ) {
        self.shouldBlock = shouldBlock
        self.onDiagnostic = onDiagnostic
    }

    func start() {
        guard timer == nil else { return }

        let timer = Timer(
            timeInterval: 0.75,
            repeats: true
        ) { [weak self] _ in
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

        let bundle = (
            app.bundleIdentifier ?? ""
        ).lowercased()

        guard !bundle.contains("iina") else { return }

        if isOfficialYouTubeApp(app) {
            if !app.terminate() {
                _ = app.forceTerminate()
            }

            lastClosedAt = Date()
            onDiagnostic(
                "Blocked the YouTube app. IINA remains available."
            )
            return
        }

        guard let mode = BrowserCatalog.interactionMode(
            for: app
        ) else {
            return
        }

        if mode == .safari || mode == .chromium {
            let bundleIdentifier =
                app.bundleIdentifier ?? ""

            if let url = activeURL(
                bundleIdentifier: bundleIdentifier,
                mode: mode
            ) {
                guard isYouTubeURL(url) else {
                    return
                }

                if closeActiveTab(
                    bundleIdentifier: bundleIdentifier,
                    mode: mode
                ) {
                    recordBrowserClose(app)
                    return
                }

                if accessibilityWindowLooksLikeYouTube(
                    app: app
                ),
                   closeFrontmostBrowserTabWithAccessibility(
                    app: app
                   ) {
                    recordBrowserClose(app)
                    return
                }

                requestAccessibilityIfNeeded(app: app)
                return
            }
        }

        if accessibilityWindowLooksLikeYouTube(app: app) {
            if closeFrontmostBrowserTabWithAccessibility(
                app: app
            ) {
                recordBrowserClose(app)
            }
            return
        }

        if !AXIsProcessTrusted() {
            requestAccessibilityIfNeeded(app: app)
        }
    }

    private func recordBrowserClose(
        _ app: NSRunningApplication
    ) {
        lastClosedAt = Date()
        lastAccessibilityDiagnosticApp = nil

        let name = app.localizedName ?? "browser"
        onDiagnostic(
            "Closed the blocked YouTube tab in \(name). IINA remains available."
        )
    }

    private func activeURL(
        bundleIdentifier: String,
        mode: BrowserInteractionMode
    ) -> String? {
        let source: String

        switch mode {
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

        case .accessibility:
            return nil
        }

        return executeAppleScript(source)
    }

    private func closeActiveTab(
        bundleIdentifier: String,
        mode: BrowserInteractionMode
    ) -> Bool {
        let source: String

        switch mode {
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

        case .accessibility:
            return false
        }

        return executeAppleScript(source) == "closed"
    }

    private func executeAppleScript(
        _ source: String
    ) -> String? {
        guard let script = NSAppleScript(
            source: source
        ) else {
            return nil
        }

        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(
            &errorInfo
        )

        guard errorInfo == nil else { return nil }
        return result.stringValue
    }

    private func accessibilityWindowLooksLikeYouTube(
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

        let focusedWindow =
            focusedWindowRef as! AXUIElement

        if windowTitleLooksLikeYouTube(
            focusedWindow
        ) {
            return true
        }

        return addressFieldLooksLikeYouTube(
            focusedWindow
        )
    }

    private func windowTitleLooksLikeYouTube(
        _ window: AXUIElement
    ) -> Bool {
        guard let title = stringAttribute(
            kAXTitleAttribute as CFString,
            from: window
        ) else {
            return false
        }

        let lower = title
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            .lowercased()

        return lower == "youtube"
            || lower.hasSuffix(" - youtube")
            || lower.hasSuffix(" — youtube")
            || lower.hasSuffix(" | youtube")
            || lower.hasSuffix(" · youtube")
    }

    private func addressFieldLooksLikeYouTube(
        _ root: AXUIElement
    ) -> Bool {
        var queue: [(AXUIElement, Int)] = [
            (root, 0)
        ]
        var index = 0
        var inspected = 0

        while index < queue.count,
              inspected < 300 {
            let (element, depth) = queue[index]
            index += 1
            inspected += 1

            if depth > 8 {
                continue
            }

            let role = stringAttribute(
                kAXRoleAttribute as CFString,
                from: element
            ) ?? ""

            if role == "AXTextField"
                || role == "AXComboBox"
                || role == "AXSearchField" {
                let candidates = [
                    stringAttribute(
                        kAXValueAttribute as CFString,
                        from: element
                    ),
                    stringAttribute(
                        kAXTitleAttribute as CFString,
                        from: element
                    ),
                    stringAttribute(
                        kAXDescriptionAttribute as CFString,
                        from: element
                    )
                ]

                if candidates
                    .compactMap({ $0 })
                    .contains(where: isYouTubeURL) {
                    return true
                }
            }

            guard depth < 8 else { continue }

            var childrenRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                element,
                kAXChildrenAttribute as CFString,
                &childrenRef
            ) == .success,
               let children =
                    childrenRef as? [AXUIElement] {
                for child in children {
                    queue.append(
                        (child, depth + 1)
                    )
                }
            }
        }

        return false
    }

    private func stringAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> String? {
        var valueRef: CFTypeRef?

        guard AXUIElementCopyAttributeValue(
            element,
            attribute,
            &valueRef
        ) == .success,
              let value = valueRef as? String
        else {
            return nil
        }

        return value
    }

    private func closeFrontmostBrowserTabWithAccessibility(
        app: NSRunningApplication
    ) -> Bool {
        guard AXIsProcessTrusted(),
              NSWorkspace.shared.frontmostApplication?
                .processIdentifier
                == app.processIdentifier
        else {
            requestAccessibilityIfNeeded(app: app)
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

        // macOS virtual key 13 is W. Command-W closes the current browser tab.
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    private func requestAccessibilityIfNeeded(
        app: NSRunningApplication
    ) {
        guard !AXIsProcessTrusted() else { return }

        if !didPromptForAccessibility {
            didPromptForAccessibility = true

            let promptKey =
                kAXTrustedCheckOptionPrompt
                    .takeUnretainedValue() as String
            let options = [
                promptKey: true
            ] as CFDictionary

            _ = AXIsProcessTrustedWithOptions(
                options
            )
        }

        let name = app.localizedName ?? "this browser"
        guard lastAccessibilityDiagnosticApp != name else {
            return
        }
        lastAccessibilityDiagnosticApp = name

        onDiagnostic(
            "To make browser-only YouTube blocking work in \(name), enable deadlock in System Settings → Privacy & Security → Accessibility. This lets Deadlock close only the active blocked browser tab; IINA remains untouched."
        )
    }

    private func isYouTubeURL(
        _ value: String
    ) -> Bool {
        let trimmed = value
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            )

        guard !trimmed.isEmpty else { return false }

        if let host = URL(
            string: trimmed
        )?.host?.lowercased() {
            return isYouTubeHost(host)
        }

        let lower = trimmed.lowercased()
        return lower.contains("youtube.com")
            || lower.contains("youtu.be")
            || lower.contains(
                "youtube-nocookie.com"
            )
    }

    private func isYouTubeHost(
        _ host: String
    ) -> Bool {
        let normalized = host.lowercased()

        return normalized == "youtube.com"
            || normalized.hasSuffix(".youtube.com")
            || normalized == "youtu.be"
            || normalized.hasSuffix(".youtu.be")
            || normalized == "youtube-nocookie.com"
            || normalized.hasSuffix(
                ".youtube-nocookie.com"
            )
    }

    private func isOfficialYouTubeApp(
        _ app: NSRunningApplication
    ) -> Bool {
        let bundle = (
            app.bundleIdentifier ?? ""
        ).lowercased()

        if bundle.contains("iina") {
            return false
        }

        if bundle == "com.google.ios.youtube"
            || bundle == "com.google.youtube" {
            return true
        }

        return app.localizedName?
            .lowercased() == "youtube"
    }
}
