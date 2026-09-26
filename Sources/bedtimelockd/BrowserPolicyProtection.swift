import Foundation
import Darwin
import DeadlockShared

/// Enforces browser-only YouTube blocking without touching DNS.
///
/// Chrome and Firefox get native browser policy while IINA/yt-dlp keep normal
/// YouTube DNS access. Existing browser policy values are snapshotted so
/// Deadlock can restore them when the distraction block is disabled.
final class BrowserPolicyProtection {
    private struct Snapshot: Codable {
        var username: String
        var chromeURLBlocklist: [String]?
        var chromeCaptured: Bool?

        var firefoxEnterprisePoliciesEnabled: Bool?
        var firefoxEnterprisePoliciesEnabledCaptured: Bool?
        var firefoxFlattenedWebsiteFilterBlock: [String]?
        var firefoxFlattenedWebsiteFilterBlockCaptured: Bool?
    }

    private let statePath =
        DeadlockPaths.support + "/browser-policy-state.json"

    private let chromeBundleID = "com.google.Chrome"
    private let firefoxPreferencesDomain =
        "/Library/Preferences/org.mozilla.firefox"
    private let firefoxPreferencesPath =
        "/Library/Preferences/org.mozilla.firefox.plist"

    private let chromeYouTubeEntries = [
        "youtube.com",
        "youtu.be",
        "youtube-nocookie.com"
    ]

    private let firefoxYouTubePatterns = [
        "*://youtube.com/*",
        "*://*.youtube.com/*",
        "*://youtu.be/*",
        "*://*.youtu.be/*",
        "*://youtube-nocookie.com/*",
        "*://*.youtube-nocookie.com/*"
    ]

    func isHealthy(youtubeBlocked: Bool) -> Bool {
        if !youtubeBlocked {
            return loadSnapshot() == nil
        }

        guard let user = consoleUserName() else {
            // Login may not have completed yet. The daemon rechecks after wake
            // and during its normal web-protection health checks.
            return true
        }

        let chromeValues = readChromePolicy(username: user)
        let chromeCurrent = stringArray(
            chromeValues["URLBlocklist"]
        )
        let chromeHealthy = chromeYouTubeEntries.allSatisfy(
            chromeCurrent.contains
        )

        let firefoxValues = readFirefoxPreferences()
        let firefoxEnabled = boolValue(
            firefoxValues["EnterprisePoliciesEnabled"]
        ) == true
        let firefoxCurrent = stringArray(
            firefoxValues["WebsiteFilter__Block"]
        )
        let firefoxHealthy = firefoxYouTubePatterns.allSatisfy(
            firefoxCurrent.contains
        )

        return chromeHealthy && firefoxEnabled && firefoxHealthy
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

        var chromeValues = readChromePolicy(username: user)
        var chromeCurrent = stringArray(
            chromeValues["URLBlocklist"]
        )

        let firefoxValues = readFirefoxPreferences()
        let flattenedFirefoxBlockPresent =
            firefoxValues["WebsiteFilter__Block"] != nil

        var firefoxCurrent: [String]
        if flattenedFirefoxBlockPresent {
            firefoxCurrent = stringArray(
                firefoxValues["WebsiteFilter__Block"]
            )
        } else if let websiteFilter =
                    firefoxValues["WebsiteFilter"]
                    as? [String: Any] {
            // Preserve an existing nested WebsiteFilter while temporarily using
            // Mozilla's supported flattened command-line form.
            firefoxCurrent = stringArray(
                websiteFilter["Block"]
            )
        } else {
            firefoxCurrent = []
        }

        var snapshot = loadSnapshot()
            ?? Snapshot(username: user)

        if snapshot.username != user {
            snapshot = Snapshot(username: user)
        }

        if snapshot.chromeCaptured != true {
            snapshot.chromeURLBlocklist =
                chromeValues["URLBlocklist"] == nil
                ? nil
                : chromeCurrent
            snapshot.chromeCaptured = true
        }

        if snapshot.firefoxEnterprisePoliciesEnabledCaptured
            != true {
            snapshot.firefoxEnterprisePoliciesEnabled =
                boolValue(
                    firefoxValues["EnterprisePoliciesEnabled"]
                )
            snapshot.firefoxEnterprisePoliciesEnabledCaptured = true
        }

        if snapshot.firefoxFlattenedWebsiteFilterBlockCaptured
            != true {
            snapshot.firefoxFlattenedWebsiteFilterBlock =
                flattenedFirefoxBlockPresent
                ? stringArray(
                    firefoxValues["WebsiteFilter__Block"]
                )
                : nil
            snapshot.firefoxFlattenedWebsiteFilterBlockCaptured =
                true
        }

        // Save the originals before changing either browser.
        try saveSnapshot(snapshot)

        for entry in chromeYouTubeEntries
            where !chromeCurrent.contains(entry) {
            chromeCurrent.append(entry)
        }
        chromeValues["URLBlocklist"] = chromeCurrent
        try writeChromePolicy(
            chromeValues,
            username: user
        )

        for pattern in firefoxYouTubePatterns
            where !firefoxCurrent.contains(pattern) {
            firefoxCurrent.append(pattern)
        }
        try writeFirefoxPolicy(blockPatterns: firefoxCurrent)
    }

    private func restorePreviousPolicy() throws {
        guard let snapshot = loadSnapshot() else { return }

        var chromeValues = readChromePolicy(
            username: snapshot.username
        )
        if let original = snapshot.chromeURLBlocklist {
            chromeValues["URLBlocklist"] = original
        } else {
            chromeValues.removeValue(
                forKey: "URLBlocklist"
            )
        }
        try writeChromePolicy(
            chromeValues,
            username: snapshot.username
        )

        if snapshot.firefoxFlattenedWebsiteFilterBlockCaptured
            == true {
            if let original =
                snapshot.firefoxFlattenedWebsiteFilterBlock {
                try writeFirefoxBlock(original)
            } else {
                deleteFirefoxPreference(
                    "WebsiteFilter__Block"
                )
            }
        }

        if snapshot.firefoxEnterprisePoliciesEnabledCaptured
            == true {
            if let original =
                snapshot.firefoxEnterprisePoliciesEnabled {
                try writeFirefoxEnterpriseEnabled(original)
            } else {
                deleteFirefoxPreference(
                    "EnterprisePoliciesEnabled"
                )
            }
        }

        try? FileManager.default.removeItem(
            atPath: statePath
        )
    }

    // MARK: - Chrome

    private func chromePolicyDirectory(
        username: String
    ) -> String {
        "/Library/Managed Preferences/\(username)"
    }

    private func chromePolicyPath(
        username: String
    ) -> String {
        chromePolicyDirectory(username: username)
            + "/\(chromeBundleID).plist"
    }

    private func readChromePolicy(
        username: String
    ) -> [String: Any] {
        readPlist(
            path: chromePolicyPath(username: username)
        )
    }

    private func writeChromePolicy(
        _ values: [String: Any],
        username: String
    ) throws {
        let fm = FileManager.default
        let directory =
            chromePolicyDirectory(username: username)

        try fm.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true
        )
        _ = chmod(directory, 0o755)
        _ = chown(directory, 0, 0)

        let path =
            chromePolicyPath(username: username)

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
            "deadlock: Chrome URLBlocklist updated at %@",
            path
        )
    }

    // MARK: - Firefox

    private func readFirefoxPreferences()
        -> [String: Any] {
        readPlist(path: firefoxPreferencesPath)
    }

    private func writeFirefoxPolicy(
        blockPatterns: [String]
    ) throws {
        try writeFirefoxEnterpriseEnabled(true)
        try writeFirefoxBlock(blockPatterns)

        NSLog(
            "deadlock: Firefox WebsiteFilter updated at %@",
            firefoxPreferencesPath
        )
    }

    private func writeFirefoxEnterpriseEnabled(
        _ enabled: Bool
    ) throws {
        let status = runProcess(
            "/usr/bin/defaults",
            [
                "write",
                firefoxPreferencesDomain,
                "EnterprisePoliciesEnabled",
                "-bool",
                enabled ? "TRUE" : "FALSE"
            ]
        )
        guard status == 0 else {
            throw NSError(
                domain: "deadlock.browser-policy",
                code: Int(status),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Could not update Firefox EnterprisePoliciesEnabled."
                ]
            )
        }
    }

    private func writeFirefoxBlock(
        _ patterns: [String]
    ) throws {
        let status = runProcess(
            "/usr/bin/defaults",
            [
                "write",
                firefoxPreferencesDomain,
                "WebsiteFilter__Block",
                "-array"
            ] + patterns
        )
        guard status == 0 else {
            throw NSError(
                domain: "deadlock.browser-policy",
                code: Int(status),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Could not update Firefox WebsiteFilter."
                ]
            )
        }
    }

    private func deleteFirefoxPreference(
        _ key: String
    ) {
        _ = runProcess(
            "/usr/bin/defaults",
            [
                "delete",
                firefoxPreferencesDomain,
                key
            ]
        )
    }

    // MARK: - Shared helpers

    private func readPlist(
        path: String
    ) -> [String: Any] {
        guard let data = try? Data(
            contentsOf: URL(fileURLWithPath: path)
        ),
        let object = try? PropertyListSerialization
            .propertyList(
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

    private func stringArray(
        _ value: Any?
    ) -> [String] {
        if let strings = value as? [String] {
            return strings
        }
        if let values = value as? [Any] {
            return values.compactMap {
                $0 as? String
            }
        }
        return []
    }

    private func boolValue(
        _ value: Any?
    ) -> Bool? {
        if let bool = value as? Bool {
            return bool
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        return nil
    }

    private func loadSnapshot() -> Snapshot? {
        guard let data = try? Data(
            contentsOf: URL(fileURLWithPath: statePath)
        ) else {
            return nil
        }
        return try? JSONDecoder().decode(
            Snapshot.self,
            from: data
        )
    }

    private func saveSnapshot(
        _ snapshot: Snapshot
    ) throws {
        let data = try JSONEncoder().encode(snapshot)
        try data.write(
            to: URL(fileURLWithPath: statePath),
            options: .atomic
        )
        _ = chmod(statePath, 0o600)
        _ = chown(statePath, 0, 0)
    }
}
