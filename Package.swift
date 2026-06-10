// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PiHoleMenuApp",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "PiHoleMenuApp",
            exclude: ["Info.plist", "Resources"]
        ),
        .testTarget(
            name: "PiHoleMenuAppTests",
            dependencies: ["PiHoleMenuApp"]
        )
    ]
)
