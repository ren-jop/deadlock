import Foundation
import IOKit
import IOKit.pwr_mgt

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
            case UInt32(kIOMessageSystemHasPoweredOn):
                me.onWake()
            case UInt32(kIOMessageCanSystemSleep):
                IOAllowPowerChange(service, Int(bitPattern: messageArgument))
            case UInt32(kIOMessageSystemWillSleep):
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
