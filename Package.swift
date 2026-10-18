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
        .executableTarget(
            name: "SPLMan",
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
