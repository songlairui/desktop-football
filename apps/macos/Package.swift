// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DesktopFootball",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "FootballPhysics", targets: ["FootballPhysics"]),
    ],
    targets: [
        // Pure, AppKit-free physics engine — fully unit-testable.
        .target(
            name: "FootballPhysics",
            path: "Sources/FootballPhysics",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The AppKit app: window-is-the-ball, CVDisplayLink-driven, CALayer-rendered.
        .executableTarget(
            name: "DesktopFootball",
            dependencies: ["FootballPhysics"],
            path: "Sources/DesktopFootball",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "FootballPhysicsTests",
            dependencies: ["FootballPhysics"],
            path: "Tests/FootballPhysicsTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
