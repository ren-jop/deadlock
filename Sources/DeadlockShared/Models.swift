import Foundation

public enum DeadlockPaths {
    public static let socket = "/var/run/deadlock.sock"

    public static let support = "/Library/Application Support/deadlock"
    public static let state = support + "/state.json"
    public static let stateSignature = support + "/state.sig"
    public static let backupState = support + "/state.backup.json"
    public static let backupSignature = support + "/state.backup.sig"
    public static let key = support + "/hmac.key"
    public static let webProtectionState = support + "/web-protection-state.json"

    // Separate last-known-good location so deleting Application Support alone
    // does not silently reset policy after a daemon restart.
    public static let recovery = "/var/db/deadlock"
    public static let recoveryKey = recovery + "/hmac.key"
    public static let recoveryState = recovery + "/state.last-valid.json"
    public static let recoverySignature = recovery + "/state.last-valid.sig"
    public static let daemonBinaryBackup = recovery + "/bedtimelockd.backup"
    public static let daemonPlistRecovery = recovery + "/com.deadlock.daemon.plist"
    public static let watchdogPlistRecovery = recovery + "/com.deadlock.watchdog.plist"

    public static let daemonBinary = "/Library/PrivilegedHelperTools/bedtimelockd"
    public static let daemonPlist = "/Library/LaunchDaemons/com.deadlock.daemon.plist"
    public static let watchdogPlist = "/Library/LaunchDaemons/com.deadlock.watchdog.plist"

    // Kept for compatibility with older installs/watchdogs.
    public static let daemonPlistBackup = support + "/com.deadlock.daemon.plist"
    public static let watchdogPlistBackup = support + "/com.deadlock.watchdog.plist"

    public static let app = "/Applications/deadlock.app"
}

public struct DaySchedule: Codable, Hashable, Sendable, Identifiable {
    public var id: Int { weekday }
    /// Calendar weekday: 1 = Sunday ... 7 = Saturday.
    public var weekday: Int
    public var enabled: Bool
    public var startMinutes: Int
    public var endMinutes: Int

    public init(weekday: Int, enabled: Bool, startMinutes: Int, endMinutes: Int) {
        self.weekday = weekday
        self.enabled = enabled
        self.startMinutes = startMinutes
        self.endMinutes = endMinutes
    }
}

public struct LockConfig: Codable, Hashable, Sendable {
    public var enabled: Bool
    public var days: [DaySchedule]
    public var contentFilterEnabled: Bool
    public var blockedWords: [String]

    public init(
        enabled: Bool,
        days: [DaySchedule],
        contentFilterEnabled: Bool = false,
        blockedWords: [String] = LockConfig.defaultBlockedWords
    ) {
        self.enabled = enabled
        self.days = days.sorted { $0.weekday < $1.weekday }
        self.contentFilterEnabled = contentFilterEnabled
        self.blockedWords = blockedWords
    }

    // Daemon-owned. The GUI does not expose editing for this list.
    public static let defaultBlockedWords = [
        "porn", "pornhub", "xvideos", "xnxx", "redtube", "xhamster", "youporn",
        "hentai", "hanime", "nhentai", "rule34", "rule 34", "rule34video",
        "onlyfans", "fapello", "spankbang", "eporner", "beeg", "tnaflix",
        "hentaihaven", "hentaifox", "hentai2read", "fakku", "e621", "e926",
        "gelbooru", "danbooru", "konachan", "yande.re", "booru"
    ]

    public static var defaultConfig: LockConfig {
        LockConfig(
            enabled: false,
            days: (1...7).map {
                DaySchedule(
                    weekday: $0,
                    enabled: true,
                    startMinutes: 23 * 60,
                    endMinutes: 6 * 60
                )
            },
            contentFilterEnabled: false,
            blockedWords: defaultBlockedWords
        )
    }
}

public struct PornSettings: Codable, Hashable, Sendable {
    public var scheduleEnabled: Bool
    public var days: [DaySchedule]
    /// Calendar weekday 1 = Sunday ... 7 = Saturday.
    public var editWeekday: Int
    public var accountabilityEnabled: Bool
    /// iMessage phone number or email. Empty disables automatic messaging.
    public var accountabilityRecipient: String
    public var motivationalOverlayEnabled: Bool
    /// Optional for backwards-compatible decoding of older persisted state.
    /// nil/false means the user has not completed first-time setup yet.
    public var setupCompleted: Bool?

    public init(
        scheduleEnabled: Bool = true,
        days: [DaySchedule] = PornSettings.defaultDays,
        editWeekday: Int = 1,
        accountabilityEnabled: Bool = true,
        accountabilityRecipient: String = "",
        motivationalOverlayEnabled: Bool = true,
        setupCompleted: Bool? = false
    ) {
        self.scheduleEnabled = scheduleEnabled
        self.days = days.sorted { $0.weekday < $1.weekday }
        self.editWeekday = min(7, max(1, editWeekday))
        self.accountabilityEnabled = accountabilityEnabled
        self.accountabilityRecipient = accountabilityRecipient
        self.motivationalOverlayEnabled = motivationalOverlayEnabled
        self.setupCompleted = setupCompleted
    }

    public static let defaultDays = (1...7).map {
        DaySchedule(
            weekday: $0,
            enabled: true,
            startMinutes: 16 * 60,
            endMinutes: 20 * 60
        )
    }

    public static var defaultSettings: PornSettings { PornSettings() }
}


public struct DistractionSettings: Codable, Hashable, Sendable {
    public var scheduleEnabled: Bool
    public var days: [DaySchedule]
    public var blockedDomains: [String]
    public var setupCompleted: Bool?

    public init(
        scheduleEnabled: Bool = false,
        days: [DaySchedule] = DistractionSettings.defaultDays,
        blockedDomains: [String] = DistractionSettings.defaultBlockedDomains,
        setupCompleted: Bool? = false
    ) {
        self.scheduleEnabled = scheduleEnabled
        self.days = days.sorted { $0.weekday < $1.weekday }
        self.blockedDomains = blockedDomains
        self.setupCompleted = setupCompleted
    }

    public static let defaultDays = (1...7).map {
        DaySchedule(
            weekday: $0,
            enabled: false,
            startMinutes: 9 * 60,
            endMinutes: 17 * 60
        )
    }

    public static let defaultBlockedDomains = [
        "instagram.com",
        "tiktok.com",
        "x.com",
        "twitter.com",
        "reddit.com",
        "facebook.com",
        "twitch.tv"
    ]

    public static var defaultSettings: DistractionSettings {
        DistractionSettings()
    }
}

public struct BedGuardVector: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }
}

public struct BedGuardSettings: Codable, Hashable, Sendable {
    public var enabled: Bool
    public var poses: [BedGuardVector]
    /// Maximum angular difference between the live gravity vector and a saved bed pose.
    public var matchAngleDegrees: Double
    /// A pose has to stay matched for this long before the daemon sleeps the Mac.
    public var sustainSeconds: Double

    public init(
        enabled: Bool = false,
        poses: [BedGuardVector] = [],
        matchAngleDegrees: Double = 26,
        sustainSeconds: Double = 20
    ) {
        self.enabled = enabled
        self.poses = poses
        self.matchAngleDegrees = matchAngleDegrees
        self.sustainSeconds = sustainSeconds
    }

    public static var defaultSettings: BedGuardSettings {
        BedGuardSettings()
    }
}

public struct PendingConfig: Codable, Hashable, Sendable {
    public var config: LockConfig
    public var activatesAt: Date

    public init(config: LockConfig, activatesAt: Date) {
        self.config = config
        self.activatesAt = activatesAt
    }
}

public struct PersistedState: Codable, Hashable, Sendable {
    public var current: LockConfig
    public var pending: PendingConfig?
    public var uninstallRequestedAt: Date?
    /// The sleep-window start that already consumed instant emergency access.
    /// Persisting this prevents daemon restarts from granting a second use in the same window.
    public var emergencyImmediateUsedForStart: Date?
    /// Active sleep-only emergency override. Persisted so daemon restarts do not cancel it.
    public var emergencyOverrideUntil: Date?
    public var updatedAt: Date

    /// Manual Porn Blocker extension. Scheduled windows are separate.
    public var pornBlockerUntil: Date?
    public var settingsLockedUntil: Date?

    /// Migration field from early builds. PornSettings is authoritative.
    public var accountabilityEnabled: Bool?
    public var pornSettings: PornSettings?

    /// Persisted accountability event so daemon/UI restarts cannot erase it.
    public var accountabilityTriggeredAt: Date?
    public var accountabilityReason: String?
    public var lastAccountabilityTriggeredAt: Date?

    /// Separate emergency-access event for friend notification. This is kept
    /// independent from porn accountability so it never opens the porn overlay.
    public var emergencyAccessTriggeredAt: Date?
    /// User-provided explanation for a deliberate emergency sleep override.
    /// Optional keeps older persisted state files decodable.
    public var emergencyAccessReason: String?

    /// Ordinary distraction blocking is separate from the stricter Porn Blocker.
    public var distractionBlockUntil: Date?
    public var distractionSettings: DistractionSettings?

    /// AirPods posture sensing is configured by the user app but enforced by the root daemon.
    /// Optional keeps older signed state files decodable after upgrading.
    public var bedGuardSettings: BedGuardSettings?

    /// Single-use dated distraction exception slot. The legacy field names are
    /// preserved so existing persisted state remains decodable across upgrades.
    public var discordOneOffAllowedUntil: Date?
    public var discordOneOffUsed: Bool?
    /// 29 Sep 2026 setup-only Discord exception. Optional for backwards-compatible decoding.
    public var discordSetupExceptionUsed: Bool?

    public init(
        current: LockConfig = .defaultConfig,
        pending: PendingConfig? = nil,
        uninstallRequestedAt: Date? = nil,
        emergencyImmediateUsedForStart: Date? = nil,
        emergencyOverrideUntil: Date? = nil,
        updatedAt: Date = Date(),
        pornBlockerUntil: Date? = nil,
        settingsLockedUntil: Date? = nil,
        accountabilityEnabled: Bool? = true,
        pornSettings: PornSettings? = nil,
        accountabilityTriggeredAt: Date? = nil,
        accountabilityReason: String? = nil,
        lastAccountabilityTriggeredAt: Date? = nil,
        emergencyAccessTriggeredAt: Date? = nil,
        emergencyAccessReason: String? = nil,
        distractionBlockUntil: Date? = nil,
        distractionSettings: DistractionSettings? = nil,
        bedGuardSettings: BedGuardSettings? = nil,
        discordOneOffAllowedUntil: Date? = nil,
        discordOneOffUsed: Bool? = nil,
        discordSetupExceptionUsed: Bool? = nil
    ) {
        self.current = current
        self.pending = pending
        self.uninstallRequestedAt = uninstallRequestedAt
        self.emergencyImmediateUsedForStart = emergencyImmediateUsedForStart
        self.emergencyOverrideUntil = emergencyOverrideUntil
        self.updatedAt = updatedAt
        self.pornBlockerUntil = pornBlockerUntil
        self.settingsLockedUntil = settingsLockedUntil
        self.accountabilityEnabled = accountabilityEnabled
        self.pornSettings = pornSettings
        self.accountabilityTriggeredAt = accountabilityTriggeredAt
        self.accountabilityReason = accountabilityReason
        self.lastAccountabilityTriggeredAt = lastAccountabilityTriggeredAt
        self.emergencyAccessTriggeredAt = emergencyAccessTriggeredAt
        self.emergencyAccessReason = emergencyAccessReason
        self.distractionBlockUntil = distractionBlockUntil
        self.distractionSettings = distractionSettings
        self.bedGuardSettings = bedGuardSettings
        self.discordOneOffAllowedUntil = discordOneOffAllowedUntil
        self.discordOneOffUsed = discordOneOffUsed
        self.discordSetupExceptionUsed = discordSetupExceptionUsed
    }
}

public struct LockInterval: Hashable, Sendable {
    public var start: Date
    public var end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }
}

public struct DaemonStatus: Codable, Hashable, Sendable {
    public var daemonRunning: Bool
    public var active: Bool
    public var nextLockStart: Date?
    public var activeEnd: Date?
    public var pendingConfigActivation: Date?
    public var configChangesBlocked: Bool
    public var emergencyReadyAt: Date?
    public var emergencyOverrideUntil: Date?
    public var emergencyImmediateAvailable: Bool
    public var emergencyAccessTriggeredAt: Date?
    public var emergencyAccessReason: String?
    public var uninstallReadyAt: Date?
    public var testWindowStart: Date?
    public var testWindowEnd: Date?

    public var pornBlockerUntil: Date?
    public var pornBlockerActive: Bool
    public var pornScheduledEnd: Date?
    public var pornScheduleNextStart: Date?
    public var pornSettingsEditableToday: Bool
    public var settingsLockedUntil: Date?

    public var accountabilityEnabled: Bool
    public var accountabilityTriggeredAt: Date?
    public var accountabilityReason: String?

    public var webProtectionHealthy: Bool
    public var webProtectionLastError: String?

    public var distractionBlockUntil: Date?
    public var distractionBlockActive: Bool
    public var distractionScheduledEnd: Date?
    public var distractionScheduleNextStart: Date?
    public var distractionSettingsEditable: Bool
    public var discordOneOffAllowedUntil: Date?

    public init(
        daemonRunning: Bool = true,
        active: Bool = false,
        nextLockStart: Date? = nil,
        activeEnd: Date? = nil,
        pendingConfigActivation: Date? = nil,
        configChangesBlocked: Bool = false,
        emergencyReadyAt: Date? = nil,
        emergencyOverrideUntil: Date? = nil,
        emergencyImmediateAvailable: Bool = false,
        emergencyAccessTriggeredAt: Date? = nil,
        emergencyAccessReason: String? = nil,
        uninstallReadyAt: Date? = nil,
        testWindowStart: Date? = nil,
        testWindowEnd: Date? = nil,
        pornBlockerUntil: Date? = nil,
        pornBlockerActive: Bool = false,
        pornScheduledEnd: Date? = nil,
        pornScheduleNextStart: Date? = nil,
        pornSettingsEditableToday: Bool = false,
        settingsLockedUntil: Date? = nil,
        accountabilityEnabled: Bool = true,
        accountabilityTriggeredAt: Date? = nil,
        accountabilityReason: String? = nil,
        webProtectionHealthy: Bool = true,
        webProtectionLastError: String? = nil,
        distractionBlockUntil: Date? = nil,
        distractionBlockActive: Bool = false,
        distractionScheduledEnd: Date? = nil,
        distractionScheduleNextStart: Date? = nil,
        distractionSettingsEditable: Bool = true,
        discordOneOffAllowedUntil: Date? = nil
    ) {
        self.daemonRunning = daemonRunning
        self.active = active
        self.nextLockStart = nextLockStart
        self.activeEnd = activeEnd
        self.pendingConfigActivation = pendingConfigActivation
        self.configChangesBlocked = configChangesBlocked
        self.emergencyReadyAt = emergencyReadyAt
        self.emergencyOverrideUntil = emergencyOverrideUntil
        self.emergencyImmediateAvailable = emergencyImmediateAvailable
        self.emergencyAccessTriggeredAt = emergencyAccessTriggeredAt
        self.emergencyAccessReason = emergencyAccessReason
        self.uninstallReadyAt = uninstallReadyAt
        self.testWindowStart = testWindowStart
        self.testWindowEnd = testWindowEnd
        self.pornBlockerUntil = pornBlockerUntil
        self.pornBlockerActive = pornBlockerActive
        self.pornScheduledEnd = pornScheduledEnd
        self.pornScheduleNextStart = pornScheduleNextStart
        self.pornSettingsEditableToday = pornSettingsEditableToday
        self.settingsLockedUntil = settingsLockedUntil
        self.accountabilityEnabled = accountabilityEnabled
        self.accountabilityTriggeredAt = accountabilityTriggeredAt
        self.accountabilityReason = accountabilityReason
        self.webProtectionHealthy = webProtectionHealthy
        self.webProtectionLastError = webProtectionLastError
        self.distractionBlockUntil = distractionBlockUntil
        self.distractionBlockActive = distractionBlockActive
        self.distractionScheduledEnd = distractionScheduledEnd
        self.distractionScheduleNextStart = distractionScheduleNextStart
        self.distractionSettingsEditable = distractionSettingsEditable
        self.discordOneOffAllowedUntil = discordOneOffAllowedUntil
    }
}

public enum IPCCommand: String, Codable, Sendable {
    case getStatus
    case getConfig
    case setConfig
    case startTest
    case startPornBlocker
    case startDistractionBlock
    case allowDiscordOneOff
    case setPornSettings
    case setDistractionSettings
    case setBedGuardSettings
    case bedGuardTrigger
    case lockSettings
    case clearAccountability
    case emergencyImmediate
    case emergencyBegin
    case emergencySubmit
    case emergencyActivate
    case uninstallRequest
    case uninstallStatus
}

public struct IPCRequest: Codable, Sendable {
    public var command: IPCCommand
    public var config: LockConfig?
    public var pornSettings: PornSettings?
    public var distractionSettings: DistractionSettings?
    public var bedGuardSettings: BedGuardSettings?
    public var text: String?
    public var seconds: Double?
    /// Used by custom-duration UI. Existing clients can omit it.
    public var date: Date?

    public init(
        command: IPCCommand,
        config: LockConfig? = nil,
        pornSettings: PornSettings? = nil,
        distractionSettings: DistractionSettings? = nil,
        bedGuardSettings: BedGuardSettings? = nil,
        text: String? = nil,
        seconds: Double? = nil,
        date: Date? = nil
    ) {
        self.command = command
        self.config = config
        self.pornSettings = pornSettings
        self.distractionSettings = distractionSettings
        self.bedGuardSettings = bedGuardSettings
        self.text = text
        self.seconds = seconds
        self.date = date
    }
}

public struct IPCResponse: Codable, Sendable {
    public var ok: Bool
    public var message: String
    public var status: DaemonStatus?
    public var config: LockConfig?
    public var pornSettings: PornSettings?
    public var distractionSettings: DistractionSettings?
    public var bedGuardSettings: BedGuardSettings?
    public var challenge: String?

    public init(
        ok: Bool,
        message: String,
        status: DaemonStatus? = nil,
        config: LockConfig? = nil,
        pornSettings: PornSettings? = nil,
        distractionSettings: DistractionSettings? = nil,
        bedGuardSettings: BedGuardSettings? = nil,
        challenge: String? = nil
    ) {
        self.ok = ok
        self.message = message
        self.status = status
        self.config = config
        self.pornSettings = pornSettings
        self.distractionSettings = distractionSettings
        self.bedGuardSettings = bedGuardSettings
        self.challenge = challenge
    }
}
