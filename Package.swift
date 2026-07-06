// swift-tools-version: 6.0
import PackageDescription

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
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-cmark.git", from: "0.4.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.1.0"),
        .package(path: "Dependency/Highlightr"),
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
            ],
            path: "Shared",
            resources: [
                .copy("Resources/Styles"),
                .copy("Resources/Themes"),
                .copy("Resources/Templates"),
                .copy("Resources/Extensions"),
                .copy("Resources/Highlight"),
                .copy("Resources/ScrollSync"),
            ]
        ),
        .executableTarget(
            name: "FenMacOS",
            dependencies: ["FenCore"],
            path: "macOS"
        ),
        .executableTarget(
            name: "FenIOS",
            dependencies: ["FenCore"],
            path: "iOS"
        ),
        .testTarget(
            name: "FenTests",
            dependencies: ["FenCore"],
            path: "Tests/FenTests"
        ),
    ]
)
