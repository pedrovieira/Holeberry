// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HoleberryCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(
            name: "HoleberryCore",
            targets: ["HoleberryCore"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/auth0/SimpleKeychain", from: "1.3.0"),
        .package(url: "https://github.com/sindresorhus/Defaults", from: "9.0.0"),
        .package(url: "https://github.com/swiftlang/swift-subprocess", from: "1.0.2"),
    ],
    targets: [
        .target(
            name: "HoleberryCore",
            dependencies: [
                .product(name: "SimpleKeychain", package: "SimpleKeychain"),
                .product(name: "Defaults", package: "Defaults"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .testTarget(
            name: "HoleberryCoreTests",
            dependencies: ["HoleberryCore"],
            exclude: ["TestSupport/Fixtures"],
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .testTarget(
            name: "HoleberryCoreIntegrationTests",
            dependencies: [
                "HoleberryCore",
                .product(name: "Defaults", package: "Defaults"),
                .product(name: "Subprocess", package: "swift-subprocess"),
            ],
            exclude: ["Containers", "README.md", "test"],
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
    ]
)
