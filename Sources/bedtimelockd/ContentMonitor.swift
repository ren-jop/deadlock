import Foundation
import AppKit
import ApplicationServices
import Darwin
import DeadlockShared

final class ContentMonitor {
    private var observers: [pid_t: AXObserver] = [:]
    private var workspaceTokens: [NSObjectProtocol] = []
    private var configProvider: () -> LockConfig
    private var onMatch: (pid_t, String) -> Void
    private let queue = DispatchQueue(label: "deadlock.content-monitor")

    init(configProvider: @escaping () -> LockConfig, onMatch: @escaping (pid_t, String) -> Void) {
        self.configProvider = configProvider
        self.onMatch = onMatch
    }

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        workspaceTokens.append(nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: nil) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.attachAndScan(app.processIdentifier)
        })
        workspaceTokens.append(nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.attachAndScan(app.processIdentifier)
        })
        for app in NSWorkspace.shared.runningApplications { attach(app.processIdentifier) }
        if let active = NSWorkspace.shared.frontmostApplication { scan(pid: active.processIdentifier) }
    }

    deinit {
        for token in workspaceTokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
    }

    func rescanFrontmost() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        attachAndScan(app.processIdentifier)
    }

    private func attachAndScan(_ pid: pid_t) {
        attach(pid)
        scan(pid: pid)
    }

    private func attach(_ pid: pid_t) {
        guard pid > 1, observers[pid] == nil, pid != getpid() else { return }
        var observer: AXObserver?
        let rc = AXObserverCreate(pid, { _, element, _, refcon in
            guard let refcon else { return }
            let me = Unmanaged<ContentMonitor>.fromOpaque(refcon).takeUnretainedValue()
            var p: pid_t = 0
            AXUIElementGetPid(element, &p)
            me.scan(pid: p)
        }, &observer)
        guard rc == .success, let observer else { return }
        let app = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXFocusedWindowChangedNotification, kAXTitleChangedNotification, kAXValueChangedNotification, kAXWindowCreatedNotification] {
            _ = AXObserverAddNotification(observer, app, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
    }

    private func scan(pid: pid_t) {
        queue.async { [weak self] in
            guard let self else { return }
            let config = self.configProvider()
            guard config.contentFilterEnabled else { return }
            let words = config.blockedWords
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
            guard !words.isEmpty else { return }

            let app = AXUIElementCreateApplication(pid)
            let text = self.collectText(app, depth: 0, budget: 250).lowercased()
            guard !text.isEmpty else { return }
            if let match = words.first(where: { text.contains($0) }) {
                self.onMatch(pid, match)
            }
        }
    }

    private func collectText(_ element: AXUIElement, depth: Int, budget: Int) -> String {
        guard depth <= 7, budget > 0 else { return "" }
        var pieces: [String] = []
        for attr in [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute, kAXHelpAttribute] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success {
                if let s = value as? String, !s.isEmpty { pieces.append(s) }
                else if let ns = value as? NSAttributedString { pieces.append(ns.string) }
            }
        }
        var childrenValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
           let children = childrenValue as? [AXUIElement] {
            var remaining = budget - 1
            for child in children.prefix(40) where remaining > 0 {
                pieces.append(collectText(child, depth: depth + 1, budget: remaining))
                remaining -= 1
            }
        }
        return pieces.joined(separator: "\n")
    }
}
