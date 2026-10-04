// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "lan-capture",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "lancapture", targets: ["LanCapture"])
    ],
    targets: [
        .executableTarget(
            name: "LanCapture",
            path: "Sources/LanCapture",
            swiftSettings: [
                .unsafeFlags(["-Xfrontend", "-strict-concurrency=minimal"])
            ]
        ),
        .testTarget(
            name: "LanCaptureTests",
            dependencies: ["LanCapture"],
            path: "Tests/LanCaptureTests"
        ),
    ]
)
