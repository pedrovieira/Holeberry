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

  /// Builds bundles carrying shared-storage metadata and removes them afterwards.
  @MainActor
  private final class Fixture {
    private var urls: [URL] = []

    func storage(
      appGroup: String? = nil,
      keychainGroup: String? = nil,
      containingApp: String? = BundleSharedStorageTests.identifier
    ) throws -> BundleSharedStorage {
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("SharedStorage-\(UUID().uuidString).bundle", isDirectory: true)
      try TestBundles.writeInfoPlist(
        at: root,
        identifier: BundleSharedStorageTests.identifier,
        containingAppIdentifier: containingApp,
        appGroupIdentifier: appGroup,
        keychainAccessGroup: keychainGroup
      )
      urls.append(root)
      return BundleSharedStorage(interactive: false, bundle: try TestBundles.bundle(at: root))
    }

    func cleanUp() {
      urls.forEach(TestBundles.remove)
    }
  }

  private func validAppGroupIdentifier() -> String {
    "group.holeberry.tests.\(UUID().uuidString)"
  }

  @Test func resolvesTheAppGroupSuite() throws {
    let fixture = Fixture()
    defer { fixture.cleanUp() }
    let identifier = validAppGroupIdentifier()
    let storage = try fixture.storage(appGroup: identifier)

    #expect(try storage.location().suiteName == identifier)
  }

  /// `UserDefaults(suiteName:)` returns a distinct instance per call, so a
  /// matching handle identity proves the second call reused the resolution.
  @Test func reusesTheResolvedAppGroupSuite() throws {
    let fixture = Fixture()
    defer { fixture.cleanUp() }
    let identifier = validAppGroupIdentifier()
    let storage = try fixture.storage(appGroup: identifier)

    let first = try storage.location()
    let second = try storage.location()
    let uncachedSuite = try #require(UserDefaults(suiteName: identifier))

    #expect(first.suite === second.suite)
    #expect(first.suite !== uncachedSuite)
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
    #expect(first === second)
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
}
