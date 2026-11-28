import Defaults
import Foundation
import Testing

@testable import HoleberryCore

/// The widget reads the completed App Group copy and nothing else.
@Suite("SharedStorageReader")
@MainActor
struct SharedStorageReaderTests {
  // MARK: - Server list without credentials

  @Test func listsSharedServersWithoutResolvingCredentials() throws {
    let harness = ReaderHarness()
    let server = ServerConfig(label: "Shared", url: "http://shared.local", version: .v6)
    Defaults[.servers(suite: harness.sharedSuite)] = [server]
    Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] = SharedStorageValidation.currentVersion

    let servers = try harness.reader.servers()

    #expect(servers.map(\.id) == [server.id])
    #expect(harness.sharedStorage.keychainCallCount == 0)
    #expect(harness.keychain.readCallCount == 0)
    #expect(harness.activationRecord == 0)
  }

  @Test func listsNoSharedServersUntilTheCopyIsComplete() {
    let harness = ReaderHarness()
    Defaults[.servers(suite: harness.sharedSuite)] = [ServerConfig(url: "http://shared.local", version: .v6)]

    #expect(throws: SharedStorageReaderError.notReady) {
      try harness.reader.servers()
    }
    #expect(harness.sharedStorage.keychainCallCount == 0)
    #expect(harness.activationRecord == 0)
  }

  @Test func listsNoSharedServersWhenTheCopyIsUnreadable() {
    let harness = ReaderHarness()
    Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] = SharedStorageValidation.currentVersion
    setRawDefaultsValue("not-an-array", for: Defaults.Keys.servers(suite: harness.sharedSuite))

    #expect(throws: SharedStorageReadinessError.malformedServerConfiguration) {
      try harness.reader.servers()
    }
    #expect(harness.sharedStorage.keychainCallCount == 0)
  }

  @Test func listsNoSharedServersWhenTheCompletionMarkerIsUnsupported() {
    let harness = ReaderHarness()
    let version = SharedStorageValidation.currentVersion + 1
    Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] = version

    #expect(throws: SharedStorageReadinessError.unsupportedCompletionVersion(version)) {
      try harness.reader.servers()
    }
    #expect(harness.sharedStorage.keychainCallCount == 0)
  }

  @Test func listsNoSharedServersWithoutACompletedServerConfiguration() {
    let harness = ReaderHarness()
    Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] = SharedStorageValidation.currentVersion

    #expect(throws: SharedStorageReadinessError.missingServerConfiguration) {
      try harness.reader.servers()
    }
    #expect(harness.sharedStorage.keychainCallCount == 0)
  }

  @Test func listsServersFromTheLatestSharedCopy() throws {
    let harness = ReaderHarness()
    let first = ServerConfig(label: "First", url: "http://first.local", version: .v6)
    Defaults[.servers(suite: harness.sharedSuite)] = [first]
    Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] = SharedStorageValidation.currentVersion

    #expect(try harness.reader.servers().map(\.id) == [first.id])

    Defaults[.servers(suite: harness.sharedSuite)] = []
    #expect(try harness.reader.servers().isEmpty)
    #expect(harness.sharedStorage.keychainCallCount == 0)
  }

  // MARK: - Connections with shared credentials

  @Test func openingSharedStorageReadsOnlyTheSharedStoreWithoutActivationOrCredentialAccess() throws {
    let harness = ReaderHarness()
    let legacy = ServerConfig(url: "http://legacy.local", version: .v5)
    let shared = ServerConfig(label: "Shared", url: "http://shared.local", version: .v6)
    Defaults[.servers(suite: harness.legacySuite)] = [legacy]
    Defaults[.servers(suite: harness.sharedSuite)] = [shared]
    Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] = SharedStorageValidation.currentVersion

    let storage = try harness.reader.openStorage()

    #expect(storage.loadServers().map(\.id) == [shared.id])
    #expect(harness.activationRecord == 0)
    #expect(Defaults[.servers(suite: harness.legacySuite)].map(\.id) == [legacy.id])
    #expect(harness.keychain.readCallCount == 0)
    #expect(harness.keychain.saveCallCount == 0)
    #expect(harness.keychain.deleteCallCount == 0)
    try harness.keychain.saveCredential("shared-secret", for: shared.id)
    #expect(try storage.readCredential(for: shared.id) == "shared-secret")
  }

  @Test func openingPendingSharedStorageDoesNotMigrateOrFallBackToLegacy() throws {
    let harness = ReaderHarness()
    let server = ServerConfig(url: "http://legacy.local", version: .v6)
    Defaults[.servers(suite: harness.legacySuite)] = [server]

    #expect(throws: SharedStorageReaderError.notReady) {
      try harness.reader.openStorage()
    }
    #expect(harness.sharedMarker == 0)
    #expect(harness.activationRecord == 0)
    #expect(harness.sharedStorage.keychainCallCount == 0)
    #expect(Defaults[.servers(suite: harness.legacySuite)].map(\.id) == [server.id])
  }

  @Test func openingSharedStorageAcceptsAnExplicitEmptyListAndRevalidatesEachTime() throws {
    let harness = ReaderHarness()
    Defaults[.servers(suite: harness.sharedSuite)] = []
    Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] = SharedStorageValidation.currentVersion

    let storage = try harness.reader.openStorage()
    #expect(storage.loadServers().isEmpty)

    Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] = 0

    #expect(throws: SharedStorageReaderError.notReady) {
      try harness.reader.openStorage()
    }
    #expect(harness.sharedStorage.keychainCallCount == 1)
  }

  @Test func openingSharedStorageRejectsUnsupportedVersionsBeforeCreatingTheKeychain() {
    let harness = ReaderHarness()
    let version = SharedStorageValidation.currentVersion + 1
    Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] = version

    #expect(throws: SharedStorageReadinessError.unsupportedCompletionVersion(version)) {
      try harness.reader.openStorage()
    }
    #expect(harness.sharedStorage.keychainCallCount == 0)
  }

  @Test func openingSharedStorageRejectsMissingAndMalformedServerLists() {
    let harness = ReaderHarness()
    Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] = SharedStorageValidation.currentVersion

    #expect(throws: SharedStorageReadinessError.missingServerConfiguration) {
      try harness.reader.openStorage()
    }
    setRawDefaultsValue("not-an-array", for: Defaults.Keys.servers(suite: harness.sharedSuite))

    #expect(throws: SharedStorageReadinessError.malformedServerConfiguration) {
      try harness.reader.openStorage()
    }
    #expect(harness.sharedStorage.keychainCallCount == 0)
  }

  @Test func openingSharedStoragePropagatesUnavailableLocation() {
    let harness = ReaderHarness()
    harness.sharedStorage.locationError = ReaderTestError.sharedLocationUnavailable

    #expect(throws: ReaderTestError.sharedLocationUnavailable) {
      try harness.reader.openStorage()
    }
    #expect(harness.sharedStorage.keychainCallCount == 0)
  }

  @Test func openingSharedStoragePropagatesUnavailableKeychain() {
    let harness = ReaderHarness()
    Defaults[.servers(suite: harness.sharedSuite)] = []
    Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] = SharedStorageValidation.currentVersion
    harness.sharedStorage.keychainError = ReaderTestError.sharedKeychainUnavailable

    #expect(throws: ReaderTestError.sharedKeychainUnavailable) {
      try harness.reader.openStorage()
    }
    #expect(harness.activationRecord == 0)
  }

  @Test func readerIgnoresMalformedLegacyConfigurationAndActivation() throws {
    let harness = ReaderHarness()
    let server = ServerConfig(url: "http://shared.local", version: .v6)
    Defaults[.servers(suite: harness.sharedSuite)] = [server]
    Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] = SharedStorageValidation.currentVersion
    setRawDefaultsValue("not-an-array", for: Defaults.Keys.servers(suite: harness.legacySuite))
    let activationKey = Defaults.Keys.sharedStorageActivatedVersion(suite: harness.legacySuite).name
    harness.legacySuite.set("invalid", forKey: activationKey)

    let storage = try harness.reader.openStorage()

    #expect(storage.loadServers().map(\.id) == [server.id])
    #expect(try harness.reader.servers().map(\.id) == [server.id])
    #expect(harness.legacySuite.string(forKey: activationKey) == "invalid")
  }
}

// MARK: - Test Support

private enum ReaderTestError: Error, Equatable {
  case sharedLocationUnavailable
  case sharedKeychainUnavailable
}

@MainActor
private final class ReaderHarness {
  let sharedSuite: UserDefaults
  let legacySuite: UserDefaults
  let legacySuiteName: String
  let appLocalSuite = TestDefaults.makeSuite()
  let keychain = MockKeychainManager()
  let sharedStorage: StubSharedStorage
  let reader: SharedStorageReader

  init() {
    let shared = TestDefaults.makeNamedSuite()
    let legacy = TestDefaults.makeNamedSuite()
    sharedSuite = shared.suite
    legacySuite = legacy.suite
    legacySuiteName = legacy.name
    let keychain = self.keychain
    sharedStorage = StubSharedStorage(
      location: SharedStorageLocation(suite: shared.suite, suiteName: shared.name),
      keychain: keychain
    )
    reader = SharedStorageReader(sharedStorage: sharedStorage, appLocalSuite: appLocalSuite)
  }

  var sharedMarker: Int {
    Defaults[.sharedStorageMigrationVersion(suite: sharedSuite)]
  }

  var activationRecord: Int {
    Defaults[.sharedStorageActivatedVersion(suite: legacySuite)]
  }
}
