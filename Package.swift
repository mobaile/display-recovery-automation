// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DisplayRecoveryAutomation",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "DisplayRecoveryCore",
            targets: ["DisplayRecoveryCore"]
        ),
        .executable(
            name: "DisplayRecoveryApp",
            targets: ["DisplayRecoveryApp"]
        ),
        .executable(
            name: "display-recovery-cli",
            targets: ["DisplayRecoveryCLI"]
        )
    ],
    targets: [
        .target(
            name: "DisplayRecoveryCore"
        ),
        .target(
            name: "MsiHid",
            dependencies: ["DisplayRecoveryCore"],
            path: "Sources/MsiHid",
            linkerSettings: [
                .linkedFramework("IOKit")
            ]
        ),
        .target(
            name: "MiotLocal",
            dependencies: ["DisplayRecoveryCore"],
            path: "Sources/MiotLocal",
            linkerSettings: [
                .linkedFramework("Network")
            ]
        ),
        .target(
            name: "DisplayRecoveryMac",
            dependencies: ["DisplayRecoveryCore", "MsiHid", "MiotLocal"],
            path: "Sources/DisplayRecoveryMac",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("IOKit"),
                .linkedFramework("Network"),
                .linkedFramework("Security")
            ]
        ),
        .executableTarget(
            name: "DisplayRecoveryApp",
            dependencies: ["DisplayRecoveryCore", "MsiHid", "DisplayRecoveryMac"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("IOKit"),
                .linkedFramework("Network"),
                .linkedFramework("Security")
            ]
        ),
        .executableTarget(
            name: "DisplayRecoveryCLI",
            dependencies: ["DisplayRecoveryCore", "MsiHid", "MiotLocal", "DisplayRecoveryMac"],
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("IOKit"),
                .linkedFramework("Network"),
                .linkedFramework("Security")
            ]
        ),
        .testTarget(
            name: "DisplayRecoveryCoreTests",
            dependencies: ["DisplayRecoveryCore"]
        ),
        .testTarget(
            name: "DisplayRecoveryPlatformTests",
            dependencies: ["DisplayRecoveryCore", "MsiHid", "MiotLocal", "DisplayRecoveryMac"]
        )
    ],
    swiftLanguageModes: [.v5]
)
