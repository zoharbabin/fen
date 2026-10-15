// swift-tools-version: 6.0
import Foundation
import PackageDescription

/// The llama.cpp binary has no iOS Simulator slice. Set FEN_WITHOUT_LLAMA=1 to build for the simulator
/// without it: downloaded models then report that this build can't run them.
let withLlama = ProcessInfo.processInfo.environment["FEN_WITHOUT_LLAMA"] == nil

let package = Package(
    name: "Fen",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
    ],
    products: [
        .library(
            name: "FenCore",
            targets: ["FenCore"]
        ),
        .executable(
            name: "Fen",
            targets: ["FenMacOS"]
        ),
        .executable(
            name: "FeniOS",
            targets: ["FenIOS"]
        ),
        .executable(
            name: "fen-export",
            targets: ["FenExportCLI"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-cmark.git", from: "0.4.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.1.0"),
        .package(path: "Dependency/Highlightr"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        .target(
            name: "FenCore",
            dependencies: [
                .product(name: "cmark-gfm", package: "swift-cmark"),
                .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
                "Yams",
                .product(name: "OrderedCollections", package: "swift-collections"),
                "Highlightr",
            ] + (withLlama ? ["llama"] : []),
            path: "Shared",
            resources: [
                .copy("Resources/Styles"),
                .copy("Resources/Themes"),
                .copy("Resources/Templates"),
                .copy("Resources/Extensions"),
                .copy("Resources/Highlight"),
                .copy("Resources/ScrollSync"),
                .copy("Resources/Emoji"),
            ]
        ),
        // llama.cpp, the engine for models you download in Settings (issue #234, docs/spikes/on-device-runtime.md).
        // Pinned to one build. The checksum is `swift package compute-checksum` of the zip.
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b11669/llama-b11669-xcframework.zip",
            checksum: "937891f26734c29c80817cdf8bf59b139c84a9c6fb36a4ad6ce31cceea608e7c"
        ),
        .executableTarget(
            name: "FenMacOS",
            dependencies: [
                "FenCore",
                .product(name: "Sparkle", package: "Sparkle", condition: .when(platforms: [.macOS])),
            ],
            path: "macOS"
        ),
        .executableTarget(
            name: "FenIOS",
            dependencies: ["FenCore"],
            path: "iOS"
        ),
        .executableTarget(
            name: "FenExportCLI",
            dependencies: ["FenCore"],
            path: "CLI/FenExportCLI"
        ),
        .testTarget(
            name: "FenTests",
            dependencies: ["FenCore"],
            path: "Tests/FenTests"
        ),
    ]
)
