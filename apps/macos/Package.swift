// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Doppler",
    platforms: [.macOS("14.2")],
    targets: [
        .executableTarget(
            name: "Doppler",
            path: "Sources/Doppler",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
