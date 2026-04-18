// swift-tools-version: 5.10
import PackageDescription

// This example package depends on the ResumeKit library via a local
// path (two levels up, at the repo root). When you clone the repo,
// `cd Examples/BasicDemo && swift run` just works — no release tag
// resolution, no network fetch.
let package = Package(
    name: "BasicDemo",
    platforms: [
        .macOS(.v12),
    ],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "BasicDemo",
            dependencies: [
                .product(name: "ResumeKit", package: "ResumeKit"),
            ]
        ),
    ]
)
