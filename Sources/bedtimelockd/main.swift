import Foundation
import DeadlockShared

if CommandLine.arguments.contains("--watchdog") {
    Watchdog().run()
} else {
    guard geteuid() == 0 else {
        fputs("bedtimelockd must run as root\n", stderr)
        exit(77)
    }
    do {
        try DeadlockDaemon().run()
    } catch {
        fputs("bedtimelockd fatal: \(error)\n", stderr)
        exit(1)
    }
}
