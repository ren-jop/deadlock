import Foundation

public enum PolicyEngine {
    public static let minimumPornDuration: TimeInterval = 15 * 60
    public static let minimumDistractionDuration: TimeInterval = 5 * 60
    public static let maximumDistractionDuration: TimeInterval = 365 * 24 * 3600
    public static let maximumPornDuration: TimeInterval = 365 * 24 * 3600
    public static let minimumSettingsGuardDuration: TimeInterval = 3600
    public static let maximumSettingsGuardDuration: TimeInterval = 365 * 24 * 3600
    public static let accountabilityCooldown: TimeInterval = 10 * 60

    public static func boundedEndDate(
        now: Date,
        seconds: Double?,
        customDate: Date?,
        minimum: TimeInterval,
        maximum: TimeInterval,
        fallback: TimeInterval
    ) -> Date {
        if let customDate {
            let raw = customDate.timeIntervalSince(now)
            return now.addingTimeInterval(min(max(raw, minimum), maximum))
        }
        let raw = seconds ?? fallback
        return now.addingTimeInterval(min(max(raw, minimum), maximum))
    }

    public static func normalizedDays(_ days: [DaySchedule]) -> [DaySchedule] {
        var byWeekday: [Int: DaySchedule] = [:]
        for day in days {
            let weekday = min(7, max(1, day.weekday))
            byWeekday[weekday] = DaySchedule(
                weekday: weekday,
                enabled: day.enabled,
                startMinutes: min(1439, max(0, day.startMinutes)),
                endMinutes: min(1439, max(0, day.endMinutes))
            )
        }
        return (1...7).map { weekday in
            byWeekday[weekday] ?? DaySchedule(
                weekday: weekday,
                enabled: false,
                startMinutes: 16 * 60,
                endMinutes: 20 * 60
            )
        }
    }

    public static func pornSettingsEditable(
        now: Date,
        settings: PornSettings,
        pornProtectionActive: Bool,
        settingsLockedUntil: Date?,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Bool {
        if let settingsLockedUntil, settingsLockedUntil > now { return false }
        if pornProtectionActive { return false }
        if settings.setupCompleted != true { return true }
        return calendar.component(.weekday, from: now) == settings.editWeekday
    }

    public static func accountabilityMayTrigger(
        now: Date,
        lastTriggeredAt: Date?,
        cooldown: TimeInterval = accountabilityCooldown
    ) -> Bool {
        guard let lastTriggeredAt else { return true }
        return now.timeIntervalSince(lastTriggeredAt) >= cooldown
    }

    /// A delayed loosening must never truncate an interval that already began
    /// under the previous configuration.
    public static func safePendingActivationDate(
        now: Date,
        pendingActivation: Date,
        activeOldInterval: LockInterval?
    ) -> Date {
        guard pendingActivation <= now,
              let activeOldInterval,
              activeOldInterval.start <= now,
              now < activeOldInterval.end
        else {
            return pendingActivation
        }
        return activeOldInterval.end
    }

    public static func distractionSettingsEditable(
        now: Date,
        distractionProtectionActive: Bool,
        settingsLockedUntil: Date?
    ) -> Bool {
        if let settingsLockedUntil, settingsLockedUntil > now { return false }
        return !distractionProtectionActive
    }

    public static func normalizedDomains(
        _ values: [String],
        limit: Int = 128
    ) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for raw in values {
            var value = raw
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()

            if let scheme = value.range(of: "://") {
                value = String(value[scheme.upperBound...])
            }
            if let slash = value.firstIndex(of: "/") {
                value = String(value[..<slash])
            }
            if let colon = value.firstIndex(of: ":") {
                value = String(value[..<colon])
            }

            while value.hasPrefix("*.") { value.removeFirst(2) }
            while value.hasPrefix(".") { value.removeFirst() }

            guard
                !value.isEmpty,
                value.count <= 253,
                value.contains("."),
                !value.contains(" "),
                value.unicodeScalars.allSatisfy({
                    CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")
                        .contains($0)
                })
            else { continue }

            if seen.insert(value).inserted {
                result.append(value)
                if result.count >= limit { break }
            }
        }

        return result
    }

}
