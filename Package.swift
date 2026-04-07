// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacDown",
    platforms: [
        .macOS(.v15),
        .iOS(.v18)
    ],
    products: [
        .library(
            name: "MacDownCore",
            targets: ["MacDownCore"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-cmark.git", from: "0.4.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.1.0"),
        .package(url: "https://github.com/raspu/Highlightr.git", from: "2.2.0"),
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
        .testTarget(
            name: "MacDownTests",
            dependencies: ["MacDownCore"],
            path: "Tests/MacDownSwiftTests"
        ),
    ]
)
