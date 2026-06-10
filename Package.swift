// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "PiHoleMenuApp",
  platforms: [
    .macOS(.v14)
  ],
  dependencies: [
    .package(url: "https://github.com/realm/SwiftLint", from: "0.55.0")
  ],
  targets: [
    .executableTarget(
      name: "PiHoleMenuApp",
      exclude: ["Info.plist", "Resources"],
      plugins: [.plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLint")]
    ),
    .testTarget(
      name: "PiHoleMenuAppTests",
      dependencies: ["PiHoleMenuApp"],
      plugins: [.plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLint")]
    )
  ]
)
