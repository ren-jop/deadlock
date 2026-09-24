import Foundation
import DeadlockShared

final class Watchdog {
    private let fm = FileManager.default

    func run() -> Never {
        while true {
            autoreleasepool { repair() }
            sleep(30)
        }
    }

    private func repair() {
        restoreIfMissing(DeadlockPaths.daemonPlist, from: DeadlockPaths.daemonPlistBackup)
        restoreIfMissing(DeadlockPaths.watchdogPlist, from: DeadlockPaths.watchdogPlistBackup)

        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        check.arguments = ["print", "system/com.deadlock.daemon"]
        check.standardOutput = FileHandle.nullDevice
        check.standardError = FileHandle.nullDevice
        do {
            try check.run(); check.waitUntilExit()
            if check.terminationStatus != 0 {
                _ = runProcess("/bin/launchctl", ["bootstrap", "system", DeadlockPaths.daemonPlist])
            }
        } catch {
            _ = runProcess("/bin/launchctl", ["bootstrap", "system", DeadlockPaths.daemonPlist])
        }
    }

    private func restoreIfMissing(_ target: String, from backup: String) {
        guard !fm.fileExists(atPath: target), fm.fileExists(atPath: backup) else { return }
        try? fm.copyItem(atPath: backup, toPath: target)
        _ = chmod(target, 0o644)
        _ = chown(target, 0, 0)
    }
}
