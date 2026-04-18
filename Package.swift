// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ResumeKit",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .tvOS(.v15),
        .watchOS(.v8),
    ],
    products: [
        .library(
            name: "ResumeKit",
            targets: ["ResumeKit"]
        ),
    ],
    dependencies: [
        // DocC plugin is a plugin dependency only — it contributes build-time
        // tooling (`swift package generate-documentation`), not a runtime
        // dependency. Users of ResumeKit inherit nothing from it.
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.4.0"),
    ],
    targets: [
        .target(
            name: "ResumeKit",
            dependencies: []
        ),
        .testTarget(
            name: "ResumeKitTests",
            dependencies: ["ResumeKit"]
        ),
    ]
)
