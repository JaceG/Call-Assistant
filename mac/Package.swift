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
        // WebRTC's audio processing (AEC3), built by scripts/build_webrtc_apm.sh.
        .binaryTarget(name: "WebRTCAPM", path: "Vendor/WebRTCAPM.xcframework"),
        .target(
            name: "CEchoCanceller",
            dependencies: ["WebRTCAPM"],
            cxxSettings: [
                .headerSearchPath("../../Vendor/webrtc-apm/include/webrtc-audio-processing-2"),
                .headerSearchPath("../../Vendor/webrtc-apm/include"),
                .define("WEBRTC_POSIX"),
                .define("WEBRTC_MAC"),
                .define("WEBRTC_LIBRARY_IMPL"),
            ],
            linkerSettings: [
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Foundation"),
                .linkedLibrary("c++"),
            ]
        ),
        .target(name: "CallCore", dependencies: ["CEchoCanceller"]),
        .executableTarget(
            name: "CallAssistant",
            dependencies: ["CallCore"]
        ),
        .testTarget(
            name: "CallCoreTests",
            dependencies: ["CallCore"]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
