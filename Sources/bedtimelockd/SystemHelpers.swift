import Foundation
import SystemConfiguration
import Darwin
import DeadlockShared

func consoleUser() -> (name: String, uid: uid_t)? {
    var uid: uid_t = 0
    var gid: gid_t = 0
    guard let name = SCDynamicStoreCopyConsoleUser(nil, &uid, &gid) as String?,
          name != "loginwindow",
          name != "_mbsetupuser"
    else { return nil }
    return (name, uid)
}

func consoleUserName() -> String? {
    consoleUser()?.name
}

func consoleUID() -> uid_t? {
    consoleUser()?.uid
}

@discardableResult
func runProcess(_ executable: String, _ arguments: [String], uid: uid_t? = nil) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: executable)
    if let uid {
        p.arguments = ["asuser", String(uid), executable] + arguments
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    } else {
        p.arguments = arguments
    }
    do {
        try p.run(); p.waitUntilExit(); return p.terminationStatus
    } catch { return -1 }
}

func notifyConsole(title: String, body: String) {
    guard let uid = consoleUID() else { return }
    let safeTitle = title.replacingOccurrences(of: "\"", with: "\\\"")
    let safeBody = body.replacingOccurrences(of: "\"", with: "\\\"")
    let script = "display notification \"\(safeBody)\" with title \"\(safeTitle)\""
    _ = runProcess("/usr/bin/osascript", ["-e", script], uid: uid)
}

func launchGUIForCountdown() {
    guard let uid = consoleUID() else { return }
    _ = runProcess("/usr/bin/open", ["-a", DeadlockPaths.app], uid: uid)
}
