// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SPLMan",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "SPLMan", targets: ["SPLMan"])
    ],
    targets: [
        .target(name: "ConsoleSockets"),
        .target(
            name: "WingKit",
            dependencies: ["ConsoleSockets"],
            linkerSettings: [
                .linkedFramework("Network")
            ]
        ),
        .target(
            name: "X32Kit",
            dependencies: ["ConsoleSockets"]
        ),
        .executableTarget(
            name: "SPLMan",
            dependencies: ["WingKit", "X32Kit"],
            resources: [.process("Resources")],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio")
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
