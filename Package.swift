// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Drain",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Drain",
            path: "Sources/Drain",
            linkerSettings: [.linkedFramework("IOKit")]
        )
    ],
    swiftLanguageModes: [.v5]
)
