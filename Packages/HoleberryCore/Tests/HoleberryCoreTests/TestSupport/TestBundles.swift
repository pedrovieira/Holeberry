import Foundation
import Testing

/// Builds throwaway bundles with controlled Info.plist metadata so tests can
/// exercise bundle-specific lookup without depending on the test host bundle.
enum TestBundles {
  static func makeAppBundle(identifier: String = "me.example.host") throws -> URL {
    try makeBundle(
      named: "HoleberryHost-\(UUID().uuidString).app",
      identifier: identifier,
      containingAppIdentifier: identifier
    )
  }

  static func makeBundle(
    named name: String,
    identifier: String,
    containingAppIdentifier: String? = nil
  ) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
    try writeInfoPlist(
      at: root,
      identifier: identifier,
      containingAppIdentifier: containingAppIdentifier
    )
    return root
  }

  static func writeInfoPlist(
    at bundleURL: URL,
    identifier: String,
    containingAppIdentifier: String? = nil,
    appGroupIdentifier: String? = nil,
    keychainAccessGroup: String? = nil
  ) throws {
    let contents = bundleURL.appendingPathComponent("Contents", isDirectory: true)
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    var plist: [String: Any] = [
      "CFBundleIdentifier": identifier,
      "CFBundleName": "Fake",
      "CFBundlePackageType": "BNDL"
    ]
    plist["HoleberryContainingAppIdentifier"] = containingAppIdentifier
    plist["HoleberryAppGroupIdentifier"] = appGroupIdentifier
    plist["HoleberryKeychainAccessGroup"] = keychainAccessGroup
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try data.write(to: contents.appendingPathComponent("Info.plist"))
  }

  static func bundle(at url: URL) throws -> Bundle {
    try #require(Bundle(url: url))
  }

  static func remove(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
  }
}
