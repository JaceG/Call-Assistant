// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "CallAssistant",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "CallCore", targets: ["CallCore"]),
        .executable(name: "CallAssistant", targets: ["CallAssistant"]),
    ],
    dependencies: [
        // FluidAudio has made source-breaking API changes in patch releases
        // (noted by OpenOats), so pin it exactly.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.13.5"),
    ],
    targets: [
        .target(
            name: "CallCore",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
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
