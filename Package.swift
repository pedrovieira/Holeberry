// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "PiHoleMenuApp",
  platforms: [
    .macOS(.v14)
  ],
  dependencies: [
    .package(url: "https://github.com/auth0/SimpleKeychain", from: "1.3.0"),
    .package(url: "https://github.com/realm/SwiftLint", from: "0.55.0"),
    .package(url: "https://github.com/sindresorhus/Defaults", from: "9.0.0"),
    .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.4.0")
  ],
  targets: [
    .executableTarget(
      name: "PiHoleMenuApp",
      dependencies: ["SimpleKeychain", "Defaults", "KeyboardShortcuts"],
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
