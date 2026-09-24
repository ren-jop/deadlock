import Foundation

public enum ScheduleEngine {
    private static func date(on day: Date, minutes: Int, calendar: Calendar) -> Date? {
        let h = minutes / 60
        let m = minutes % 60
        return calendar.date(
            bySettingHour: h,
            minute: m,
            second: 0,
            of: day,
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        )
    }

    public static func intervals(around now: Date, config: LockConfig) -> [LockInterval] {
        guard config.enabled else { return [] }
        var cal = Calendar.autoupdatingCurrent
        cal.timeZone = .autoupdatingCurrent
        let today = cal.startOfDay(for: now)
        var result: [LockInterval] = []

        for offset in -2...8 {
            guard let day = cal.date(byAdding: .day, value: offset, to: today) else { continue }
            let weekday = cal.component(.weekday, from: day)
            guard let schedule = config.days.first(where: { $0.weekday == weekday && $0.enabled }) else { continue }
            guard let start = date(on: day, minutes: schedule.startMinutes, calendar: cal) else { continue }

            let endDay: Date
            if schedule.endMinutes <= schedule.startMinutes {
                guard let next = cal.date(byAdding: .day, value: 1, to: day) else { continue }
                endDay = next
            } else {
                endDay = day
            }
            guard let end = date(on: endDay, minutes: schedule.endMinutes, calendar: cal), end > start else { continue }
            result.append(LockInterval(start: start, end: end))
        }
        return result.sorted { $0.start < $1.start }
    }

    public static func activeInterval(at now: Date, config: LockConfig) -> LockInterval? {
        intervals(around: now, config: config).first { $0.start <= now && now < $0.end }
    }

    public static func nextInterval(after now: Date, config: LockConfig) -> LockInterval? {
        intervals(around: now, config: config).first { $0.start > now }
    }

    public static func nextRelevantDate(after now: Date, config: LockConfig, pending: PendingConfig? = nil) -> Date? {
        var dates: [Date] = []
        if let active = activeInterval(at: now, config: config) { dates.append(active.end) }
        if let next = nextInterval(after: now, config: config) {
            dates.append(next.start)
            dates.append(next.start.addingTimeInterval(-300))
            dates.append(next.start.addingTimeInterval(-60))
        }
        if let pending, pending.activatesAt > now { dates.append(pending.activatesAt) }
        return dates.filter { $0 > now }.min()
    }

    public static func weeklyCoverage(_ config: LockConfig) -> [Bool] {
        var bits = Array(repeating: false, count: 7 * 1440)
        guard config.enabled else { return bits }
        for day in config.days where day.enabled {
            let dayIndex = (day.weekday - 1 + 7) % 7
            let start = day.startMinutes
            let end = day.endMinutes
            if end > start {
                for m in start..<end { bits[dayIndex * 1440 + m] = true }
            } else {
                for m in start..<1440 { bits[dayIndex * 1440 + m] = true }
                let nextDay = (dayIndex + 1) % 7
                for m in 0..<end { bits[nextDay * 1440 + m] = true }
            }
        }
        return bits
    }

    public static func isLoosening(from old: LockConfig, to new: LockConfig) -> Bool {
        let a = weeklyCoverage(old)
        let b = weeklyCoverage(new)
        for i in a.indices where a[i] && !b[i] { return true }
        return false
    }
}
