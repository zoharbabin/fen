// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacDown",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
    ],
    products: [
        .library(
            name: "MacDownCore",
            targets: ["MacDownCore"]
        ),
        .executable(
            name: "MacDownSwift",
            targets: ["MacDownMacOS"]
        ),
        .executable(
            name: "MacDowniOS",
            targets: ["MacDownIOS"]
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
            name: "MacDownCore",
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
            ]
        ),
        .executableTarget(
            name: "MacDownMacOS",
            dependencies: ["MacDownCore"],
            path: "macOS"
        ),
        .executableTarget(
            name: "MacDownIOS",
            dependencies: ["MacDownCore"],
            path: "iOS"
        ),
        .testTarget(
            name: "MacDownTests",
            dependencies: ["MacDownCore"],
            path: "Tests/MacDownSwiftTests"
        ),
    ]
)
