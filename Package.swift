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
    dependencies: [],
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
