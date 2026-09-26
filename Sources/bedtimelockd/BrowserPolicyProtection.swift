import Foundation
import Darwin
import DeadlockShared

/// Enforces browser-only YouTube blocking without touching DNS.
///
/// Chrome on macOS reads mandatory policy from:
///   /Library/Managed Preferences/<user>/com.google.Chrome.plist
///
/// Using URLBlocklist here keeps youtube.com reachable to IINA/yt-dlp while
/// Chrome itself refuses navigation. The previous value is snapshotted so
/// Deadlock can restore it when the distraction block is disabled.
final class BrowserPolicyProtection {
    private struct Snapshot: Codable {
        var username: String
        var chromeURLBlocklist: [String]?
    }

    private let statePath = DeadlockPaths.support + "/browser-policy-state.json"
    private let chromeBundleID = "com.google.Chrome"
    private let youtubeEntries = [
        "youtube.com",
        "youtu.be",
        "youtube-nocookie.com"
    ]

    func isHealthy(youtubeBlocked: Bool) -> Bool {
        if !youtubeBlocked {
            return loadSnapshot() == nil
        }

        guard let user = consoleUserName() else {
            // Login may not have completed yet. The daemon rechecks web
            // protection periodically and after wake.
            return true
        }

        let values = readPolicy(username: user)
        let current = stringArray(values["URLBlocklist"])
        return youtubeEntries.allSatisfy(current.contains)
    }

    func apply(youtubeBlocked: Bool) throws {
        if youtubeBlocked {
            try enableYouTubeBlock()
        } else {
            try restorePreviousPolicy()
        }
    }

    private func enableYouTubeBlock() throws {
        guard let user = consoleUserName() else { return }

        var values = readPolicy(username: user)
        var current = stringArray(values["URLBlocklist"])

        if loadSnapshot()?.username != user {
            try saveSnapshot(
                Snapshot(
                    username: user,
                    chromeURLBlocklist: values["URLBlocklist"] == nil ? nil : current
                )
            )
        }

        for entry in youtubeEntries where !current.contains(entry) {
            current.append(entry)
        }
        values["URLBlocklist"] = current

        try writePolicy(values, username: user)
    }

    private func restorePreviousPolicy() throws {
        guard let snapshot = loadSnapshot() else { return }

        var values = readPolicy(username: snapshot.username)
        if let original = snapshot.chromeURLBlocklist {
            values["URLBlocklist"] = original
        } else {
            values.removeValue(forKey: "URLBlocklist")
        }

        try writePolicy(values, username: snapshot.username)
        try? FileManager.default.removeItem(atPath: statePath)
    }

    private func policyDirectory(username: String) -> String {
        "/Library/Managed Preferences/\(username)"
    }

    private func policyPath(username: String) -> String {
        policyDirectory(username: username) + "/\(chromeBundleID).plist"
    }

    private func readPolicy(username: String) -> [String: Any] {
        let path = policyPath(username: username)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ),
              let dictionary = object as? [String: Any]
        else {
            return [:]
        }
        return dictionary
    }

    private func writePolicy(_ values: [String: Any], username: String) throws {
        let fm = FileManager.default
        let directory = policyDirectory(username: username)
        try fm.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true
        )
        _ = chmod(directory, 0o755)
        _ = chown(directory, 0, 0)

        let path = policyPath(username: username)
        if values.isEmpty {
            try? fm.removeItem(atPath: path)
            return
        }

        let data = try PropertyListSerialization.data(
            fromPropertyList: values,
            format: .xml,
            options: 0
        )
        try data.write(
            to: URL(fileURLWithPath: path),
            options: .atomic
        )
        _ = chmod(path, 0o644)
        _ = chown(path, 0, 0)

        NSLog(
            "deadlock: Chrome mandatory URLBlocklist updated at %@",
            path
        )
    }

    private func stringArray(_ value: Any?) -> [String] {
        if let strings = value as? [String] {
            return strings
        }
        if let values = value as? [Any] {
            return values.compactMap { $0 as? String }
        }
        return []
    }

    private func loadSnapshot() -> Snapshot? {
        guard let data = try? Data(
            contentsOf: URL(fileURLWithPath: statePath)
        ) else {
            return nil
        }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    private func saveSnapshot(_ snapshot: Snapshot) throws {
        let data = try JSONEncoder().encode(snapshot)
        try data.write(
            to: URL(fileURLWithPath: statePath),
            options: .atomic
        )
        _ = chmod(statePath, 0o600)
        _ = chown(statePath, 0, 0)
    }
}
