// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BarTab",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "BarTab",
            path: "Sources/BarTab",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
