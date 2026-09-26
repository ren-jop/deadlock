import Foundation
import IOKit
import IOKit.pwr_mgt

// These IOKit message macros are no longer imported reliably by current Swift.
// Values are the public IOMessage.h constants used by IORegisterForSystemPower.
private let deadlockIOMessageCanSystemSleep: UInt32 = 0xe0000270
private let deadlockIOMessageSystemWillSleep: UInt32 = 0xe0000280
private let deadlockIOMessageSystemHasPoweredOn: UInt32 = 0xe0000300

final class PowerMonitor {
    private var rootPort: io_connect_t = 0
    private var notifier: IONotificationPortRef?
    private var notificationObject: io_object_t = 0
    private let onWake: () -> Void

    init(onWake: @escaping () -> Void) {
        self.onWake = onWake
    }

    func start() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(context, &notifier, { refcon, service, messageType, messageArgument in
            guard let refcon else { return }
            let me = Unmanaged<PowerMonitor>.fromOpaque(refcon).takeUnretainedValue()
            switch messageType {
            case deadlockIOMessageSystemHasPoweredOn:
                me.onWake()
            case deadlockIOMessageCanSystemSleep:
                IOAllowPowerChange(service, Int(bitPattern: messageArgument))
            case deadlockIOMessageSystemWillSleep:
                IOAllowPowerChange(service, Int(bitPattern: messageArgument))
            default:
                break
            }
        }, &notificationObject)
        guard rootPort != 0, let notifier else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(notifier).takeUnretainedValue(), .defaultMode)
    }

    deinit {
        if notificationObject != 0 { IOObjectRelease(notificationObject) }
        if rootPort != 0 { IOServiceClose(rootPort) }
        if let notifier { IONotificationPortDestroy(notifier) }
    }
}
