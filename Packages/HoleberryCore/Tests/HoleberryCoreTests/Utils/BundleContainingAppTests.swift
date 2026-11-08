import Foundation
import Testing

@testable import HoleberryCore

@Suite("Bundle containing app identity")
@MainActor
struct BundleContainingAppTests {
  @Test func appAndExtensionWithMarkersShareTheAppService() throws {
    let appURL = try makeAppBundle(appIdentifier: "me.example.host")
    let appExtensionURL = try makeAppExtensionBundle(
      in: appURL,
      identifier: "me.example.host.widgets"
    )
    defer { try? FileManager.default.removeItem(at: appURL) }

    let appBundle = try #require(Bundle(url: appURL))
    let appExtensionBundle = try #require(Bundle(url: appExtensionURL))
    let appService = Bundle.containingAppIdentifier(startingAt: appBundle) + ".shared"
    let appExtensionService = Bundle.containingAppIdentifier(startingAt: appExtensionBundle) + ".shared"

    #expect(appBundle.bundleIdentifier == "me.example.host")
    #expect(appExtensionBundle.bundleIdentifier == "me.example.host.widgets")
    #expect(appService == "me.example.host.shared")
    #expect(appExtensionService == appService)
  }

  @Test func extensionWithoutHostBundleResolvesMarkerFromOwnInfo() throws {
    let extensionURL = try makeBundle(
      named: "StandaloneWidgets-\(UUID().uuidString).appex",
      identifier: "me.example.host.widgets",
      containingAppIdentifier: "me.example.host"
    )
    defer { try? FileManager.default.removeItem(at: extensionURL) }

    let extensionBundle = try #require(Bundle(url: extensionURL))

    #expect(Bundle.containingAppIdentifier(startingAt: extensionBundle) == "me.example.host")
    #expect(
      Bundle.containingAppIdentifier(startingAt: extensionBundle) + ".shared"
        == "me.example.host.shared")
  }

  @Test func appWithoutMarkerFallsBackToCurrentAppIdentifier() throws {
    let appURL = try makeBundle(named: "Markerless-\(UUID().uuidString).app", identifier: "me.example.host")
    defer { try? FileManager.default.removeItem(at: appURL) }

    let appBundle = try #require(Bundle(url: appURL))

    #expect(Bundle.containingAppIdentifier(startingAt: appBundle) == Bundle.appIdentifier)
  }

  @Test func bundleOutsideAnAppFallsBackToTheCurrentAppIdentifier() throws {
    let standaloneURL = try makeBundle(
      named: "HoleberryStandalone-\(UUID().uuidString).bundle",
      identifier: "me.example.standalone"
    )
    defer { try? FileManager.default.removeItem(at: standaloneURL) }

    let standaloneBundle = try #require(Bundle(url: standaloneURL))

    #expect(standaloneBundle.bundleIdentifier == "me.example.standalone")
    #expect(Bundle.containingAppIdentifier(startingAt: standaloneBundle) == Bundle.appIdentifier)
  }

  @Test func emptyOrUnexpandedMarkerIsRejected() throws {
    for marker in ["", "  ", "$(HOLEBERRY_APP_BUNDLE_IDENTIFIER)"] {
      let extensionURL = try makeBundle(
        named: "InvalidMarker-\(UUID().uuidString).appex",
        identifier: "me.example.host.widgets",
        containingAppIdentifier: marker
      )
      defer { try? FileManager.default.removeItem(at: extensionURL) }

      let extensionBundle = try #require(Bundle(url: extensionURL))

      #expect(Bundle.containingAppIdentifier(startingAt: extensionBundle) == Bundle.appIdentifier)
    }
  }

  @Test func nestedBundleDoesNotInheritAncestorAppMarker() throws {
    let appURL = try makeAppBundle(appIdentifier: "me.example.host")
    let toolURL = appURL.appendingPathComponent(
      "Contents/Developer/usr/bin/Tool",
      isDirectory: true
    )
    try writeInfoPlist(at: toolURL, identifier: "com.example.toolchain.tool")
    defer { try? FileManager.default.removeItem(at: appURL) }

    let appBundle = try #require(Bundle(url: appURL))
    let toolBundle = try #require(Bundle(url: toolURL))

    #expect(Bundle.containingAppIdentifier(startingAt: appBundle) == "me.example.host")
    #expect(Bundle.containingAppIdentifier(startingAt: toolBundle) == Bundle.appIdentifier)
  }

  private func makeAppBundle(appIdentifier: String) throws -> URL {
    try makeBundle(
      named: "HoleberryHost-\(UUID().uuidString).app",
      identifier: appIdentifier,
      containingAppIdentifier: appIdentifier
    )
  }

  private func makeAppExtensionBundle(in appURL: URL, identifier: String) throws -> URL {
    let contents = appURL.appendingPathComponent("Contents", isDirectory: true)
    let appExtensionURL = contents.appendingPathComponent(
      "PlugIns/HostWidgets-\(UUID().uuidString).appex",
      isDirectory: true
    )
    try writeInfoPlist(
      at: appExtensionURL,
      identifier: identifier,
      containingAppIdentifier: "me.example.host"
    )
    return appExtensionURL
  }

  private func makeBundle(
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

  private func writeInfoPlist(
    at bundleURL: URL,
    identifier: String,
    containingAppIdentifier: String? = nil
  ) throws {
    let contents = bundleURL.appendingPathComponent("Contents", isDirectory: true)
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    var plist: [String: Any] = [
      "CFBundleIdentifier": identifier,
      "CFBundleName": "Fake",
      "CFBundlePackageType": "BNDL"
    ]
    plist["HoleberryContainingAppIdentifier"] = containingAppIdentifier
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try data.write(to: contents.appendingPathComponent("Info.plist"))
  }
}
