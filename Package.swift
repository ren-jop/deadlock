// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "deadlock",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DeadlockShared", targets: ["DeadlockShared"]),
        .executable(name: "BedtimeLock", targets: ["BedtimeLock"]),
        .executable(name: "bedtimelockd", targets: ["bedtimelockd"]),
    ],
    targets: [
        .target(name: "DeadlockShared"),
        .executableTarget(
            name: "BedtimeLock",
            dependencies: ["DeadlockShared"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("UserNotifications"),
            ]
        ),
        .executableTarget(
            name: "bedtimelockd",
            dependencies: ["DeadlockShared"],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AppKit"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("Security"),
                .linkedFramework("CryptoKit"),
            ]
        ),
    ]
)
