// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "CallAssistant",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "CallCore", targets: ["CallCore"]),
        .executable(name: "CallAssistant", targets: ["CallAssistant"]),
    ],
    targets: [
        .target(name: "CallCore"),
        .executableTarget(
            name: "CallAssistant",
            dependencies: ["CallCore"]
        ),
        .testTarget(
            name: "CallCoreTests",
            dependencies: ["CallCore"]
        ),
    ]
)
