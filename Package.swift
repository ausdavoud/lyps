// swift-tools-version: 6.2
import PackageDescription

let settings: [SwiftSetting] = [.swiftLanguageMode(.v5), .enableUpcomingFeature("BareSlashRegexLiterals")]

let package = Package(
    name: "Lyps",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "Lyps", swiftSettings: settings),
        .testTarget(name: "LypsTests", dependencies: ["Lyps"], swiftSettings: settings),
    ]
)
