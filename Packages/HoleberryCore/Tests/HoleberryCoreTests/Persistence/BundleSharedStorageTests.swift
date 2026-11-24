import Foundation
import Testing

@testable import HoleberryCore

@Suite("BundleSharedStorage")
@MainActor
struct BundleSharedStorageTests {
  private static let appGroupKey = "HoleberryAppGroupIdentifier"
  private static let keychainGroupKey = "HoleberryKeychainAccessGroup"
  private static let containingAppKey = "HoleberryContainingAppIdentifier"
  nonisolated private static let identifier = "me.example.host"

  /// A bundle whose Info.plist can change between calls, so a test can prove a
  /// failed resolution is not cached as a value.
  private final class MutableBundle: Bundle, @unchecked Sendable {
    var metadata: [String: Any] = [:]

    override var infoDictionary: [String: Any]? { metadata }
  }

  /// Builds bundles carrying shared-storage metadata and removes them afterwards.
  @MainActor
  private final class Fixture {
    private var urls: [URL] = []

    func storage(
      interactive: Bool = false,
      appGroup: String? = nil,
      keychainGroup: String? = nil,
      containingApp: String? = BundleSharedStorageTests.identifier,
      identifier: String = BundleSharedStorageTests.identifier
    ) throws -> BundleSharedStorage {
      let bundle = try makeBundle(
        appGroup: appGroup,
        keychainGroup: keychainGroup,
        containingApp: containingApp,
        identifier: identifier
      )
      return BundleSharedStorage(interactive: interactive, bundle: bundle)
    }

    func makeBundle(
      appGroup: String? = nil,
      keychainGroup: String? = nil,
      containingApp: String? = BundleSharedStorageTests.identifier,
      identifier: String = BundleSharedStorageTests.identifier
    ) throws -> MutableBundle {
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("SharedStorage-\(UUID().uuidString).bundle", isDirectory: true)
      try TestBundles.writeInfoPlist(
        at: root,
        identifier: identifier,
        containingAppIdentifier: containingApp,
        appGroupIdentifier: appGroup,
        keychainAccessGroup: keychainGroup
      )
      urls.append(root)
      let bundle = try #require(MutableBundle(url: root))
      var metadata: [String: Any] = [:]
      if let appGroup { metadata["HoleberryAppGroupIdentifier"] = appGroup }
      if let keychainGroup { metadata["HoleberryKeychainAccessGroup"] = keychainGroup }
      if let containingApp { metadata["HoleberryContainingAppIdentifier"] = containingApp }
      bundle.metadata = metadata
      return bundle
    }

    func cleanUp() {
      urls.forEach(TestBundles.remove)
    }
  }

  private func validAppGroupIdentifier() -> String {
    "group.holeberry.tests.\(UUID().uuidString)"
  }

  @Test func resolvesTheAppGroupSuiteOnce() throws {
    let fixture = Fixture()
    defer { fixture.cleanUp() }
    let identifier = validAppGroupIdentifier()
    let storage = try fixture.storage(appGroup: identifier)

    let first = try storage.location()
    let second = try storage.location()

    #expect(first.suiteName == identifier)
    #expect(first.suite === second.suite)
  }

  @Test func rejectsMissingBlankAndUnexpandedMetadata() throws {
    let fixture = Fixture()
    defer { fixture.cleanUp() }

    let missing = try fixture.storage()
    #expect(throws: BundleMetadataError.missingInfoValue(Self.appGroupKey)) {
      try missing.location()
    }

    let blank = try fixture.storage(appGroup: "   ")
    #expect(throws: BundleMetadataError.missingInfoValue(Self.appGroupKey)) {
      try blank.location()
    }

    let unexpanded = try fixture.storage(appGroup: "$(HOLEBERRY_APP_GROUP)")
    #expect(throws: BundleMetadataError.invalidInfoValue(Self.appGroupKey)) {
      try unexpanded.location()
    }
  }

  @Test func rejectsIdentifiersWithoutAGroupPrefix() throws {
    let fixture = Fixture()
    defer { fixture.cleanUp() }

    let bare = try fixture.storage(appGroup: "me.pedrovieira.holeberry")
    #expect(throws: BundleMetadataError.invalidInfoValue(Self.appGroupKey)) {
      try bare.location()
    }

    let prefixOnly = try fixture.storage(appGroup: "group.")
    #expect(throws: BundleMetadataError.invalidInfoValue(Self.appGroupKey)) {
      try prefixOnly.location()
    }

    let empty = try fixture.storage(appGroup: "")
    #expect(throws: BundleMetadataError.missingInfoValue(Self.appGroupKey)) {
      try empty.location()
    }
  }

  @Test func resolvesTheSharedCredentialStoreOnce() throws {
    let fixture = Fixture()
    defer { fixture.cleanUp() }
    let storage = try fixture.storage(
      keychainGroup: "TEAMID.me.pedrovieira.holeberry.shared"
    )

    let first = try #require(try storage.keychain() as? KeychainManager)
    let second = try #require(try storage.keychain() as? KeychainManager)

    #expect(first.service == "me.example.host.shared")
    #expect(first.accessGroup == "TEAMID.me.pedrovieira.holeberry.shared")
    #expect(!first.isInteractive)
    #expect(first.usesDataProtectionKeychain)
    #expect(first === second)
  }

  @Test func widgetAndAppDeriveTheSameSharedService() throws {
    let fixture = Fixture()
    defer { fixture.cleanUp() }
    let appStorage = try fixture.storage(
      keychainGroup: "TEAMID.me.example.shared",
      identifier: "me.example.host"
    )
    let widgetStorage = try fixture.storage(
      keychainGroup: "TEAMID.me.example.shared",
      identifier: "me.example.host.widgets"
    )

    let app = try #require(try appStorage.keychain() as? KeychainManager)
    let widget = try #require(try widgetStorage.keychain() as? KeychainManager)

    #expect(app.service == "me.example.host.shared")
    #expect(widget.service == app.service)
  }

  @Test func interactiveConstructionMayPrompt() throws {
    let fixture = Fixture()
    defer { fixture.cleanUp() }
    let storage = try fixture.storage(
      interactive: true,
      keychainGroup: "TEAMID.me.example.shared"
    )

    let keychain = try #require(try storage.keychain() as? KeychainManager)

    #expect(keychain.isInteractive)
  }

  @Test func reportsMissingCredentialMetadata() throws {
    let fixture = Fixture()
    defer { fixture.cleanUp() }
    let storage = try fixture.storage(
      keychainGroup: "TEAMID.me.pedrovieira.holeberry.shared",
      containingApp: nil
    )

    #expect(throws: BundleMetadataError.missingInfoValue(Self.containingAppKey)) {
      try storage.keychain()
    }
  }

  @Test func failedResolutionIsRetriedAndSuccessIsCached() throws {
    let fixture = Fixture()
    defer { fixture.cleanUp() }
    let identifier = validAppGroupIdentifier()
    let bundle = try fixture.makeBundle()
    let storage = BundleSharedStorage(interactive: false, bundle: bundle)

    // No metadata yet: both resolutions fail and nothing is remembered.
    #expect(throws: BundleMetadataError.missingInfoValue(Self.appGroupKey)) {
      try storage.location()
    }
    #expect(throws: BundleMetadataError.missingInfoValue(Self.keychainGroupKey)) {
      try storage.keychain()
    }

    // Valid metadata: the retry succeeds.
    bundle.metadata = [
      Self.appGroupKey: identifier,
      Self.keychainGroupKey: "TEAMID.me.example.shared",
      Self.containingAppKey: Self.identifier
    ]
    #expect(try storage.location().suiteName == identifier)
    let keychain = try #require(try storage.keychain() as? KeychainManager)
    #expect(keychain.service == "me.example.host.shared")

    // Successful handles are cached: later metadata changes do not matter.
    bundle.metadata = [:]
    #expect(try storage.location().suiteName == identifier)
    let cached = try #require(try storage.keychain() as? KeychainManager)
    #expect(cached === keychain)
  }
}
