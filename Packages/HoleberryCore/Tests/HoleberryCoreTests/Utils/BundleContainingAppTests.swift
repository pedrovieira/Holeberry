import Foundation
import Testing

@testable import HoleberryCore

@Suite("Bundle containing app identity")
@MainActor
struct BundleContainingAppTests {
  @Test func appAndExtensionWithMarkersShareTheAppService() throws {
    let appURL = try TestBundles.makeAppBundle()
    let appExtensionURL = try makeAppExtensionBundle(
      in: appURL,
      identifier: "me.example.host.widgets"
    )
    defer { TestBundles.remove(appURL) }

    let appBundle = try TestBundles.bundle(at: appURL)
    let appExtensionBundle = try TestBundles.bundle(at: appExtensionURL)
    let appService = try Bundle.containingAppIdentifier(startingAt: appBundle) + ".shared"
    let appExtensionService = try Bundle.containingAppIdentifier(startingAt: appExtensionBundle) + ".shared"

    #expect(appBundle.bundleIdentifier == "me.example.host")
    #expect(appExtensionBundle.bundleIdentifier == "me.example.host.widgets")
    #expect(appService == "me.example.host.shared")
    #expect(appExtensionService == appService)
  }

  @Test func extensionWithoutHostBundleResolvesMarkerFromOwnInfo() throws {
    let extensionURL = try TestBundles.makeBundle(
      named: "StandaloneWidgets-\(UUID().uuidString).appex",
      identifier: "me.example.host.widgets",
      containingAppIdentifier: "me.example.host"
    )
    defer { TestBundles.remove(extensionURL) }

    let extensionBundle = try TestBundles.bundle(at: extensionURL)

    #expect(try Bundle.containingAppIdentifier(startingAt: extensionBundle) == "me.example.host")
    #expect(
      try Bundle.containingAppIdentifier(startingAt: extensionBundle) + ".shared"
        == "me.example.host.shared")
  }

  @Test func appWithoutMarkerThrows() throws {
    let appURL = try TestBundles.makeBundle(
      named: "Markerless-\(UUID().uuidString).app",
      identifier: "me.example.host"
    )
    defer { TestBundles.remove(appURL) }

    let appBundle = try TestBundles.bundle(at: appURL)

    #expect(
      throws: BundleMetadataError.missingInfoValue("HoleberryContainingAppIdentifier")
    ) {
      try Bundle.containingAppIdentifier(startingAt: appBundle)
    }
  }

  @Test func bundleOutsideAnAppThrows() throws {
    let standaloneURL = try TestBundles.makeBundle(
      named: "HoleberryStandalone-\(UUID().uuidString).bundle",
      identifier: "me.example.standalone"
    )
    defer { TestBundles.remove(standaloneURL) }

    let standaloneBundle = try TestBundles.bundle(at: standaloneURL)

    #expect(standaloneBundle.bundleIdentifier == "me.example.standalone")
    #expect(
      throws: BundleMetadataError.missingInfoValue("HoleberryContainingAppIdentifier")
    ) {
      try Bundle.containingAppIdentifier(startingAt: standaloneBundle)
    }
  }

  @Test func blankMarkerIsRejected() throws {
    for marker in ["", "  "] {
      let extensionURL = try TestBundles.makeBundle(
        named: "InvalidMarker-\(UUID().uuidString).appex",
        identifier: "me.example.host.widgets",
        containingAppIdentifier: marker
      )
      defer { TestBundles.remove(extensionURL) }

      let extensionBundle = try TestBundles.bundle(at: extensionURL)

      #expect(
        throws: BundleMetadataError.missingInfoValue("HoleberryContainingAppIdentifier")
      ) {
        try Bundle.containingAppIdentifier(startingAt: extensionBundle)
      }
    }
  }

  @Test func unexpandedMarkerIsRejected() throws {
    for marker in ["$(HOLEBERRY_APP_BUNDLE_IDENTIFIER)", "${HOLEBERRY_APP_BUNDLE_IDENTIFIER}"] {
      let extensionURL = try TestBundles.makeBundle(
        named: "UnexpandedMarker-\(UUID().uuidString).appex",
        identifier: "me.example.host.widgets",
        containingAppIdentifier: marker
      )
      defer { TestBundles.remove(extensionURL) }

      let extensionBundle = try TestBundles.bundle(at: extensionURL)

      #expect(
        throws: BundleMetadataError.invalidInfoValue("HoleberryContainingAppIdentifier")
      ) {
        try Bundle.containingAppIdentifier(startingAt: extensionBundle)
      }
    }
  }

  @Test func nestedBundleDoesNotInheritAncestorAppMarker() throws {
    let appURL = try TestBundles.makeAppBundle()
    let toolURL = appURL.appendingPathComponent(
      "Contents/Developer/usr/bin/Tool",
      isDirectory: true
    )
    try TestBundles.writeInfoPlist(at: toolURL, identifier: "com.example.toolchain.tool")
    defer { TestBundles.remove(appURL) }

    let appBundle = try TestBundles.bundle(at: appURL)
    let toolBundle = try TestBundles.bundle(at: toolURL)

    #expect(try Bundle.containingAppIdentifier(startingAt: appBundle) == "me.example.host")
    #expect(
      throws: BundleMetadataError.missingInfoValue("HoleberryContainingAppIdentifier")
    ) {
      try Bundle.containingAppIdentifier(startingAt: toolBundle)
    }
  }

  @Test func sharedMetadataReadsValidatedBundledValues() throws {
    let bundle = try makeMetadataBundle(
      appGroupIdentifier: " group.me.example.tests ",
      keychainAccessGroup: "TEAMID.me.example.tests.shared"
    )
    defer { TestBundles.remove(bundle.bundleURL) }

    #expect(try bundle.sharedAppGroupIdentifier() == "group.me.example.tests")
    #expect(try bundle.sharedKeychainAccessGroup() == "TEAMID.me.example.tests.shared")
  }

  @Test func missingSharedMetadataThrows() throws {
    let missingAppGroup = try makeMetadataBundle(
      keychainAccessGroup: "TEAMID.me.example.tests.shared"
    )
    defer { TestBundles.remove(missingAppGroup.bundleURL) }
    #expect(throws: BundleMetadataError.missingInfoValue("HoleberryAppGroupIdentifier")) {
      try missingAppGroup.sharedAppGroupIdentifier()
    }

    let missingKeychain = try makeMetadataBundle(
      appGroupIdentifier: "group.me.example.tests"
    )
    defer { TestBundles.remove(missingKeychain.bundleURL) }
    #expect(throws: BundleMetadataError.missingInfoValue("HoleberryKeychainAccessGroup")) {
      try missingKeychain.sharedKeychainAccessGroup()
    }
  }

  @Test func blankSharedMetadataThrows() throws {
    let blankAppGroup = try makeMetadataBundle(
      appGroupIdentifier: "  ",
      keychainAccessGroup: "TEAMID.me.example.tests.shared"
    )
    defer { TestBundles.remove(blankAppGroup.bundleURL) }
    #expect(throws: BundleMetadataError.missingInfoValue("HoleberryAppGroupIdentifier")) {
      try blankAppGroup.sharedAppGroupIdentifier()
    }

    let blankKeychain = try makeMetadataBundle(
      appGroupIdentifier: "group.me.example.tests",
      keychainAccessGroup: "  "
    )
    defer { TestBundles.remove(blankKeychain.bundleURL) }
    #expect(throws: BundleMetadataError.missingInfoValue("HoleberryKeychainAccessGroup")) {
      try blankKeychain.sharedKeychainAccessGroup()
    }
  }

  @Test func unresolvedSharedMetadataBuildSubstitutionThrows() throws {
    for (appGroup, keychainGroup) in [
      ("$(APP_GROUP)", "$(AppIdentifierPrefix)me.example.tests.shared"),
      ("${APP_GROUP}", "${AppIdentifierPrefix}me.example.tests.shared"),
      ("group.$(APP_GROUP_SUFFIX)", "$(AppIdentifierPrefix)app.tests.shared"),
      ("group.${APP_GROUP_SUFFIX}", "${AppIdentifierPrefix}app.tests.shared")
    ] {
      let bundle = try makeMetadataBundle(
        appGroupIdentifier: appGroup,
        keychainAccessGroup: keychainGroup
      )
      defer { TestBundles.remove(bundle.bundleURL) }

      #expect(throws: BundleMetadataError.invalidInfoValue("HoleberryAppGroupIdentifier")) {
        try bundle.sharedAppGroupIdentifier()
      }
      #expect(throws: BundleMetadataError.invalidInfoValue("HoleberryKeychainAccessGroup")) {
        try bundle.sharedKeychainAccessGroup()
      }
    }
  }

  @Test func nonGroupAppGroupIdentifierMetadataThrows() throws {
    let bundle = try makeMetadataBundle(
      appGroupIdentifier: "me.example.tests",
      keychainAccessGroup: "TEAMID.me.example.tests.shared"
    )
    defer { TestBundles.remove(bundle.bundleURL) }

    #expect(throws: BundleMetadataError.invalidInfoValue("HoleberryAppGroupIdentifier")) {
      try bundle.sharedAppGroupIdentifier()
    }
  }

  private func makeMetadataBundle(
    appGroupIdentifier: String? = nil,
    keychainAccessGroup: String? = nil
  ) throws -> Bundle {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "HoleberryMetadata-\(UUID().uuidString).bundle",
      isDirectory: true
    )
    try TestBundles.writeInfoPlist(
      at: root,
      identifier: "me.example.tests",
      appGroupIdentifier: appGroupIdentifier,
      keychainAccessGroup: keychainAccessGroup
    )
    return try TestBundles.bundle(at: root)
  }

  private func makeAppExtensionBundle(in appURL: URL, identifier: String) throws -> URL {
    let contents = appURL.appendingPathComponent("Contents", isDirectory: true)
    let appExtensionURL = contents.appendingPathComponent(
      "PlugIns/HostWidgets-\(UUID().uuidString).appex",
      isDirectory: true
    )
    try TestBundles.writeInfoPlist(
      at: appExtensionURL,
      identifier: identifier,
      containingAppIdentifier: "me.example.host"
    )
    return appExtensionURL
  }
}
