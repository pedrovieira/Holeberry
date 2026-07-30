// swift-tools-version: 5.10
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
    ],
    targets: [
        .target(
            name: "HoleberryCore",
            dependencies: [
                .product(name: "SimpleKeychain", package: "SimpleKeychain"),
                .product(name: "Defaults", package: "Defaults"),
            ]
        ),
        .testTarget(
            name: "HoleberryCoreTests",
            dependencies: ["HoleberryCore"]
        ),
    ]
)
