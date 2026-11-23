import Foundation
import Testing

@testable import HoleberryCore

@Suite("BundleSharedStorage")
@MainActor
struct BundleSharedStorageTests {
  private static let appGroupKey = "HoleberryAppGroupIdentifier"
  private static let keychainGroupKey = "HoleberryKeychainAccessGroup"
  private static let containingAppKey = "HoleberryContainingAppIdentifier"

  private func makeBundle(_ fixture: [String: Any] = [:]) throws -> StubBundle {
    try #require(StubBundle(fixture: fixture))
  }

  private func validAppGroupIdentifier() -> String {
    "group.holeberry.tests.\(UUID().uuidString)"
  }

  @Test func resolvesTheAppGroupSuiteOnce() throws {
    let identifier = validAppGroupIdentifier()
    let bundle = try makeBundle([Self.appGroupKey: identifier])
    let storage = BundleSharedStorage(interactive: false, bundle: bundle)

    let first = try storage.location()
    let second = try storage.location()

    #expect(first.suiteName == identifier)
    #expect(second.suiteName == identifier)
    #expect(bundle.infoReadCount == 1)
  }

  @Test func retriesUntilResolutionSucceeds() throws {
    let bundle = try makeBundle()
    let storage = BundleSharedStorage(interactive: false, bundle: bundle)

    #expect(throws: BundleMetadataError.missingInfoValue(Self.appGroupKey)) {
      try storage.location()
    }
    #expect(bundle.infoReadCount == 1)

    let identifier = validAppGroupIdentifier()
    bundle.fixture = [Self.appGroupKey: identifier]
    #expect(try storage.location().suiteName == identifier)

    // Resolved once, then cached.
    _ = try storage.location()
    #expect(bundle.infoReadCount == 2)
  }

  @Test func rejectsMissingBlankAndUnexpandedMetadata() throws {
    let missing = try makeBundle()
    #expect(throws: BundleMetadataError.missingInfoValue(Self.appGroupKey)) {
      try BundleSharedStorage(interactive: false, bundle: missing).location()
    }

    let blank = try makeBundle([Self.appGroupKey: "   "])
    #expect(throws: BundleMetadataError.missingInfoValue(Self.appGroupKey)) {
      try BundleSharedStorage(interactive: false, bundle: blank).location()
    }

    let unexpanded = try makeBundle([Self.appGroupKey: "$(HOLEBERRY_APP_GROUP)"])
    #expect(throws: BundleMetadataError.invalidInfoValue(Self.appGroupKey)) {
      try BundleSharedStorage(interactive: false, bundle: unexpanded).location()
    }
  }

  @Test func rejectsIdentifiersWithoutAGroupPrefix() throws {
    let bare = try makeBundle([Self.appGroupKey: "me.pedrovieira.holeberry"])
    #expect(throws: BundleMetadataError.invalidInfoValue(Self.appGroupKey)) {
      try BundleSharedStorage(interactive: false, bundle: bare).location()
    }

    let prefixOnly = try makeBundle([Self.appGroupKey: "group."])
    #expect(throws: BundleMetadataError.invalidInfoValue(Self.appGroupKey)) {
      try BundleSharedStorage(interactive: false, bundle: prefixOnly).location()
    }

    let empty = try makeBundle([Self.appGroupKey: ""])
    #expect(throws: BundleMetadataError.missingInfoValue(Self.appGroupKey)) {
      try BundleSharedStorage(interactive: false, bundle: empty).location()
    }
  }

  @Test func resolvesTheSharedCredentialStoreOnce() throws {
    let bundle = try makeBundle([
      Self.keychainGroupKey: "TEAMID.me.pedrovieira.holeberry.shared",
      Self.containingAppKey: "me.pedrovieira.holeberry"
    ])
    let storage = BundleSharedStorage(interactive: false, bundle: bundle)

    let first = try #require(try storage.keychain() as? KeychainManager)
    let readsAfterFirstCall = bundle.infoReadCount
    let second = try #require(try storage.keychain() as? KeychainManager)

    #expect(first.service == "me.pedrovieira.holeberry.shared")
    #expect(first.accessGroup == "TEAMID.me.pedrovieira.holeberry.shared")
    #expect(!first.isInteractive)
    #expect(first === second)
    #expect(bundle.infoReadCount == readsAfterFirstCall)
  }

  @Test func reportsMissingCredentialMetadata() throws {
    let bundle = try makeBundle([Self.keychainGroupKey: "TEAMID.me.pedrovieira.holeberry.shared"])
    let storage = BundleSharedStorage(interactive: false, bundle: bundle)

    #expect(throws: BundleMetadataError.missingInfoValue(Self.containingAppKey)) {
      try storage.keychain()
    }
  }
}
