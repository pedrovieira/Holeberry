import Defaults
import Foundation
import Testing

@testable import HoleberryCore

/// Reference error used to prove identity is preserved (not rebuilt) across the adapter.
private final class AppStorageTestError: Error, CustomStringConvertible {
  let marker: String

  init(_ marker: String) {
    self.marker = marker
  }

  var description: String { "AppStorageTestError(\(marker))" }
}

@MainActor
@Suite("AppStorage")
struct AppStorageTests {
  /// Ordinary reads report no connections for a value that cannot be decoded.
  /// Startup owns the decision to preserve it and block editing.
  @Test func unreadableSavedListLoadsAsNoServers() {
    let suite = TestDefaults.makeSuite()
    let key = Defaults.Keys.servers(suite: suite)
    setRawDefaultsValue("not-an-array", for: key)
    let storage = ConcreteAppStorage(
      sharedDataSuite: suite,
      appLocalSuite: TestDefaults.makeSuite(),
      keychain: MockKeychainManager()
    )

    #expect(storage.loadServers().isEmpty)
  }

  /// Startup never hands out this adapter with editing enabled; it must not
  /// pretend that settings or credentials are available.
  @Test func unavailableStorageReportsNothingAndRefusesCredentials() {
    let storage = UnavailableAppStorage()
    let id = UUID()

    #expect(storage.loadServers().isEmpty)
    #expect(storage.loadTemporaryUnblocks(for: id).isEmpty)
    #expect(throws: PiholeServerMutationError.storageUnavailable) {
      _ = try storage.readCredential(for: id)
    }
    #expect(throws: PiholeServerMutationError.storageUnavailable) {
      try storage.saveCredential("secret", for: id)
    }
    #expect(throws: PiholeServerMutationError.storageUnavailable) {
      try storage.deleteCredential(for: id)
    }
    #expect(throws: PiholeServerMutationError.storageUnavailable) {
      try storage.removeServer(id: id)
    }
  }

  private func makeConfig(
    id: UUID = UUID(), label: String? = nil, icon: String? = nil, url: String, version: ServerVersion
  ) -> ServerConfig {
    ServerConfig(id: id, label: label, icon: icon, url: url, version: version)
  }

  private func expectConfigEquals(_ actual: ServerConfig, _ expected: ServerConfig) {
    #expect(actual.id == expected.id)
    #expect(actual.label == expected.label)
    #expect(actual.icon == expected.icon)
    #expect(actual.url == expected.url)
    #expect(actual.version == expected.version)
  }

  private func expectRecordEquals(_ actual: TempUnblockRecord, _ expected: TempUnblockRecord) {
    #expect(actual.domain == expected.domain)
    #expect(actual.uuid == expected.uuid)
    #expect(actual.startDateUTC == expected.startDateUTC)
    #expect(actual.durationSeconds == expected.durationSeconds)
    #expect(actual.pendingRemoval == expected.pendingRemoval)
    #expect(actual.retryCount == expected.retryCount)
  }

  // MARK: - Compatibility

  @Test("loads existing arrays with all fields")
  func loadsExistingArraysWithAllFields() {
    let sharedDataSuite = TestDefaults.makeSuite()
    let appLocalSuite = TestDefaults.makeSuite()
    let first = makeConfig(
      label: "Alpha", icon: "star", url: "http://alpha.local/admin", version: .v5)
    let second = makeConfig(
      label: "Beta", icon: "bolt", url: "https://beta.local:8443", version: .v6)
    Defaults[.servers(suite: sharedDataSuite)] = [first, second]

    let records = [
      TempUnblockRecord(
        domain: "Example.COM",
        uuid: "token-1",
        startDateUTC: Date(timeIntervalSince1970: 1_700_000_000),
        durationSeconds: 3_600,
        pendingRemoval: true,
        retryCount: 2
      ),
      TempUnblockRecord(
        domain: "mixed.Case.Example",
        uuid: "token-2",
        startDateUTC: Date(timeIntervalSince1970: 1_700_000_500),
        durationSeconds: 604_800,
        pendingRemoval: false,
        retryCount: 0
      )
    ]
    Defaults[.tempUnblocks(for: second.id, suite: appLocalSuite)] = records

    let storage = ConcreteAppStorage(
      sharedDataSuite: sharedDataSuite,
      appLocalSuite: appLocalSuite,
      keychain: MockKeychainManager()
    )

    let servers = storage.loadServers()
    #expect(servers.count == 2)
    expectConfigEquals(servers[0], first)
    expectConfigEquals(servers[1], second)

    let loadedRecords = storage.loadTemporaryUnblocks(for: second.id)
    #expect(loadedRecords.count == 2)
    for (index, expected) in records.enumerated() {
      expectRecordEquals(loadedRecords[index], expected)
    }
    // A missing server key reads as empty.
    #expect(storage.loadTemporaryUnblocks(for: UUID()).isEmpty)
  }

  @Test("save uses existing keys and persists empty arrays")
  func saveUsesExistingKeys() throws {
    let sharedDataSuite = TestDefaults.makeSuite()
    let appLocalSuite = TestDefaults.makeSuite()
    let storage = ConcreteAppStorage(
      sharedDataSuite: sharedDataSuite,
      appLocalSuite: appLocalSuite,
      keychain: MockKeychainManager()
    )
    let first = makeConfig(label: "First", icon: "star", url: "http://first.local", version: .v5)
    let second = makeConfig(label: nil, icon: nil, url: "http://second.local", version: .v6)
    let serverID = first.id
    let record = TempUnblockRecord(
      domain: "save.example",
      uuid: "token-save",
      startDateUTC: Date(timeIntervalSince1970: 1_700_001_000),
      durationSeconds: 300,
      pendingRemoval: true,
      retryCount: 1
    )

    storage.saveServers([first, second])
    storage.saveTemporaryUnblocks([record], for: serverID)

    let savedConfigs: [ServerConfig] = Defaults[.servers(suite: sharedDataSuite)]
    #expect(savedConfigs.count == 2)
    expectConfigEquals(savedConfigs[0], first)
    expectConfigEquals(savedConfigs[1], second)

    let savedRecords: [TempUnblockRecord] = Defaults[.tempUnblocks(for: serverID, suite: appLocalSuite)]
    #expect(savedRecords.count == 1)
    expectRecordEquals(savedRecords[0], record)

    // Replacing with an empty array persists an empty array under the same keys.
    storage.saveServers([])
    storage.saveTemporaryUnblocks([], for: serverID)
    #expect(Defaults[.servers(suite: sharedDataSuite)].isEmpty)
    #expect(Defaults[.tempUnblocks(for: serverID, suite: appLocalSuite)].isEmpty)
    #expect(sharedDataSuite.object(forKey: "servers") != nil)
    #expect(appLocalSuite.object(forKey: "tempUnblocks-\(serverID.uuidString)") != nil)
  }

  @Test("loads read the current backing store")
  func loadsReadCurrentBackingStore() {
    let sharedDataSuite = TestDefaults.makeSuite()
    let appLocalSuite = TestDefaults.makeSuite()
    let storage = ConcreteAppStorage(
      sharedDataSuite: sharedDataSuite,
      appLocalSuite: appLocalSuite,
      keychain: MockKeychainManager()
    )
    #expect(storage.loadServers().isEmpty)

    let external = makeConfig(label: "External", icon: "globe", url: "http://external.local", version: .v6)
    Defaults[.servers(suite: sharedDataSuite)] = [external]
    let records = [
      TempUnblockRecord(
        domain: "external.example",
        uuid: "token-external",
        startDateUTC: Date(timeIntervalSince1970: 1_700_002_000),
        durationSeconds: 120
      )
    ]
    Defaults[.tempUnblocks(for: external.id, suite: appLocalSuite)] = records

    let servers = storage.loadServers()
    #expect(servers.count == 1)
    expectConfigEquals(servers[0], external)
    let loadedRecords = storage.loadTemporaryUnblocks(for: external.id)
    #expect(loadedRecords.count == 1)
    expectRecordEquals(loadedRecords[0], records[0])
  }

  // MARK: - Separation

  @Test("separates suites and server records")
  func separatesSuitesAndServerRecords() {
    let sharedDataSuite = TestDefaults.makeSuite()
    let appLocalSuite = TestDefaults.makeSuite()
    let firstID = UUID()
    let secondID = UUID()
    let appLocalSentinel = makeConfig(
      label: "App-Local Suite Sentinel", icon: "x", url: "http://sentinel.local", version: .v5)
    let sharedDataSentinel = makeConfig(
      label: "Shared-Data Suite Sentinel", icon: "y", url: "http://config-sentinel.local", version: .v6)
    Defaults[.servers(suite: appLocalSuite)] = [appLocalSentinel]
    Defaults[.servers(suite: sharedDataSuite)] = [sharedDataSentinel]

    let sharedDataSentinelRecords = [
      TempUnblockRecord(
        domain: "shared-data-suite-sentinel.example",
        uuid: "config-sentinel",
        startDateUTC: Date(timeIntervalSince1970: 1_700_003_000),
        durationSeconds: 60
      )
    ]
    Defaults[.tempUnblocks(for: firstID, suite: sharedDataSuite)] = sharedDataSentinelRecords

    let secondIDRecords = [
      TempUnblockRecord(
        domain: "second-server.example",
        uuid: "second-token",
        startDateUTC: Date(timeIntervalSince1970: 1_700_004_000),
        durationSeconds: 7200,
        retryCount: 3
      )
    ]
    Defaults[.tempUnblocks(for: secondID, suite: appLocalSuite)] = secondIDRecords

    let keychain = MockKeychainManager()
    let storage = ConcreteAppStorage(
      sharedDataSuite: sharedDataSuite, appLocalSuite: appLocalSuite,
      keychain: keychain)

    let replacement = [
      makeConfig(label: "Replacement", icon: "r", url: "http://replacement.local", version: .v6)
    ]
    storage.saveServers(replacement)
    let newRecord = TempUnblockRecord(
      domain: "first-server.example",
      uuid: "first-token",
      startDateUTC: Date(timeIntervalSince1970: 1_700_005_000),
      durationSeconds: 600
    )
    storage.saveTemporaryUnblocks([newRecord], for: firstID)

    // The assigned suite alone changes; the other suite keeps its sentinels.
    let savedConfigs: [ServerConfig] = Defaults[.servers(suite: sharedDataSuite)]
    #expect(savedConfigs.count == 1)
    expectConfigEquals(savedConfigs[0], replacement[0])
    let untouchedConfigs: [ServerConfig] = Defaults[.servers(suite: appLocalSuite)]
    #expect(untouchedConfigs.count == 1)
    expectConfigEquals(untouchedConfigs[0], appLocalSentinel)

    let firstRecords: [TempUnblockRecord] = Defaults[.tempUnblocks(for: firstID, suite: appLocalSuite)]
    #expect(firstRecords.count == 1)
    expectRecordEquals(firstRecords[0], newRecord)
    let untouchedSentinel: [TempUnblockRecord] = Defaults[.tempUnblocks(for: firstID, suite: sharedDataSuite)]
    #expect(untouchedSentinel.count == 1)
    expectRecordEquals(untouchedSentinel[0], sharedDataSentinelRecords[0])

    // Another server's records are intact.
    let secondRecords: [TempUnblockRecord] = Defaults[.tempUnblocks(for: secondID, suite: appLocalSuite)]
    #expect(secondRecords.count == 1)
    expectRecordEquals(secondRecords[0], secondIDRecords[0])
    #expect(storage.loadTemporaryUnblocks(for: secondID).count == 1)

    // Saving servers leaves credentials and temporary records alone.
    try? keychain.saveCredential("keep-me", for: firstID)
    storage.saveServers([makeConfig(label: "Again", url: "http://again.local", version: .v5)])
    #expect(keychain.storedCredentials[firstID.uuidString] == "keep-me")
    #expect(Defaults[.tempUnblocks(for: firstID, suite: appLocalSuite)].count == 1)
    #expect(Defaults[.tempUnblocks(for: secondID, suite: appLocalSuite)].count == 1)
  }

  // MARK: - Read isolation

  @Test("server loads read only the shared-data suite", arguments: [true, false])
  func serverLoadsUseOnlySharedDataSuite(intendedStorePopulated: Bool) {
    let sharedDataSuite = TestDefaults.makeSuite()
    let appLocalSuite = TestDefaults.makeSuite()
    let intended = [
      makeConfig(label: "Intended", icon: "star", url: "http://intended.local", version: .v5),
      makeConfig(label: "Second", icon: "bolt", url: "https://second.local:8443", version: .v6)
    ]
    let decoy = [
      makeConfig(label: "Decoy", icon: "x", url: "http://decoy.local", version: .v6)
    ]
    Defaults[.servers(suite: appLocalSuite)] = decoy
    if intendedStorePopulated {
      Defaults[.servers(suite: sharedDataSuite)] = intended
    }
    let storage = ConcreteAppStorage(
      sharedDataSuite: sharedDataSuite, appLocalSuite: appLocalSuite,
      keychain: MockKeychainManager())

    let loaded = storage.loadServers()

    if intendedStorePopulated {
      #expect(loaded.count == intended.count)
      for (index, expected) in intended.enumerated() where index < loaded.count {
        expectConfigEquals(loaded[index], expected)
      }
    } else {
      #expect(
        loaded.isEmpty,
        "configurations must never fall back to the app-local suite")
    }
  }

  @Test("temporary records read only the app-local suite", arguments: [true, false])
  func temporaryUnblocksUseOnlyAppLocalSuite(intendedStorePopulated: Bool) {
    let sharedDataSuite = TestDefaults.makeSuite()
    let appLocalSuite = TestDefaults.makeSuite()
    let serverID = UUID()
    let intended = [
      TempUnblockRecord(
        domain: "Intended.Example",
        uuid: "intended-token",
        startDateUTC: Date(timeIntervalSince1970: 1_700_009_000),
        durationSeconds: 900,
        pendingRemoval: true,
        retryCount: 2
      ),
      TempUnblockRecord(
        domain: "Second.Example",
        uuid: "second-token",
        startDateUTC: Date(timeIntervalSince1970: 1_700_009_500),
        durationSeconds: 3_600
      )
    ]
    let decoy = [
      TempUnblockRecord(
        domain: "decoy.example",
        uuid: "decoy-token",
        startDateUTC: Date(timeIntervalSince1970: 1_600_000_000),
        durationSeconds: 60
      )
    ]
    Defaults[.tempUnblocks(for: serverID, suite: sharedDataSuite)] = decoy
    if intendedStorePopulated {
      Defaults[.tempUnblocks(for: serverID, suite: appLocalSuite)] = intended
    }
    let storage = ConcreteAppStorage(
      sharedDataSuite: sharedDataSuite, appLocalSuite: appLocalSuite,
      keychain: MockKeychainManager())

    let loaded = storage.loadTemporaryUnblocks(for: serverID)

    if intendedStorePopulated {
      #expect(loaded.count == intended.count)
      for (index, expected) in intended.enumerated() where index < loaded.count {
        expectRecordEquals(loaded[index], expected)
      }
    } else {
      #expect(
        loaded.isEmpty,
        "temporary records must never fall back to the shared-data suite")
    }
  }

  // MARK: - Credentials

  @Test func clearingTheActivePasswordKeepsTheMigrationCopyUntilConnectionDeletion() throws {
    let sharedData = TestDefaults.makeNamedSuite()
    let legacy = MockKeychainManager()
    let shared = MockKeychainManager()
    let server = ServerConfig(url: "http://saved.local", version: .v6)
    let storage = ConcreteAppStorage(
      sharedDataSuite: sharedData.suite,
      appLocalSuite: TestDefaults.makeSuite(),
      keychain: shared,
      legacyKeychain: legacy
    )
    storage.saveServers([server])
    try legacy.saveCredential("legacy-secret", for: server.id)
    try shared.saveCredential("active-secret", for: server.id)

    try storage.deleteCredential(for: server.id)
    #expect(try legacy.readCredential(for: server.id) == "legacy-secret")
    #expect(try shared.readCredential(for: server.id) == nil)

    try storage.removeServer(id: server.id)
    #expect(try legacy.readCredential(for: server.id) == nil)
    #expect(storage.loadServers().isEmpty)
  }

  @Test func legacyCleanupFailureStillDeletesTheActiveCredential() throws {
    let legacy = MockKeychainManager()
    let shared = MockKeychainManager()
    let id = UUID()
    try legacy.saveCredential("original-secret", for: id)
    try shared.saveCredential("active-secret", for: id)
    let failure = AppStorageTestError("legacy-locked")
    legacy.errorStub = failure
    let sharedData = TestDefaults.makeNamedSuite()
    let storage = ConcreteAppStorage(
      sharedDataSuite: sharedData.suite,
      appLocalSuite: TestDefaults.makeSuite(),
      keychain: shared,
      legacyKeychain: legacy
    )

    let error = #expect(throws: AppStorageTestError.self) {
      try storage.removeServer(id: id)
    }

    #expect(error === failure)
    #expect(try shared.readCredential(for: id) == nil)
  }

  @Test func activeCredentialDeletionFailurePreservesLegacyCredentialAndConnection() throws {
    let legacy = MockKeychainManager()
    let active = MockKeychainManager()
    let server = ServerConfig(url: "http://saved.local", version: .v6)
    let failure = AppStorageTestError("active-locked")
    try legacy.saveCredential("legacy-secret", for: server.id)
    try active.saveCredential("active-secret", for: server.id)
    active.deleteErrorStub = failure
    let sharedData = TestDefaults.makeNamedSuite()
    let storage = ConcreteAppStorage(
      sharedDataSuite: sharedData.suite,
      appLocalSuite: TestDefaults.makeSuite(),
      keychain: active,
      legacyKeychain: legacy
    )
    storage.saveServers([server])

    let error = #expect(throws: AppStorageTestError.self) {
      try storage.removeServer(id: server.id)
    }

    #expect(error === failure)
    #expect(active.deleteCallCount == 1)
    #expect(legacy.deleteCallCount == 0)
    #expect(try active.readCredential(for: server.id) == "active-secret")
    #expect(try legacy.readCredential(for: server.id) == "legacy-secret")
    #expect(storage.loadServers().map(\.id) == [server.id])
  }

  @Test("credential reads ignore decoy values in both defaults suites")
  func credentialReadsIgnoreDefaultsDecoys() throws {
    let sharedDataSuite = TestDefaults.makeSuite()
    let appLocalSuite = TestDefaults.makeSuite()
    let keychain = MockKeychainManager()
    let storage = ConcreteAppStorage(
      sharedDataSuite: sharedDataSuite, appLocalSuite: appLocalSuite,
      keychain: keychain)
    let serverID = UUID()

    // Synthetic test-only keys: production has no credential defaults key.
    sharedDataSuite.set("decoy-shared-data-credential", forKey: "testOnlyDecoyCredential")
    appLocalSuite.set("decoy-app-local-credential", forKey: "testOnlyDecoyCredential")
    sharedDataSuite.set(
      "decoy-shared-data-credential-\(serverID.uuidString)",
      forKey: "testOnlyDecoyCredential-\(serverID.uuidString)")
    appLocalSuite.set(
      "decoy-app-local-credential-\(serverID.uuidString)",
      forKey: "testOnlyDecoyCredential-\(serverID.uuidString)")

    #expect(try storage.readCredential(for: serverID) == nil)
    #expect(keychain.readCredentialCallCount == 1)
    #expect(keychain.lastReadServerID == serverID)
    #expect(keychain.storedCredentials[serverID.uuidString] == nil)
  }

  @Test("credential roundtrip goes only to the injected keychain")
  func credentialRoundtrip() throws {
    let sharedData = TestDefaults.makeNamedSuite()
    let appLocal = TestDefaults.makeNamedSuite()
    let keychain = MockKeychainManager()
    let storage = ConcreteAppStorage(
      sharedDataSuite: sharedData.suite, appLocalSuite: appLocal.suite,
      keychain: keychain)
    let serverID = UUID()
    let secret = "super-secret-token"
    let sharedDataBaseline = NSDictionary(
      dictionary: sharedData.suite.persistentDomain(forName: sharedData.name) ?? [:])
    let appLocalBaseline = NSDictionary(
      dictionary: appLocal.suite.persistentDomain(forName: appLocal.name) ?? [:])

    /// Neither suite may gain, lose, or change a key during any credential operation.
    /// Reading the exact domain keeps this independent of the merged search list.
    func expectNoSuiteWrites(_ moment: String) {
      let sharedDataNow = NSDictionary(
        dictionary: sharedData.suite.persistentDomain(forName: sharedData.name) ?? [:])
      let appLocalNow = NSDictionary(
        dictionary: appLocal.suite.persistentDomain(forName: appLocal.name) ?? [:])
      #expect(sharedDataNow.isEqual(sharedDataBaseline), "shared-data suite changed \(moment)")
      #expect(appLocalNow.isEqual(appLocalBaseline), "app-local suite changed \(moment)")
    }

    #expect(try storage.readCredential(for: serverID) == nil)
    #expect(keychain.readCredentialCallCount == 1)
    #expect(keychain.lastReadServerID == serverID)
    expectNoSuiteWrites("during an absent read")

    try storage.saveCredential(secret, for: serverID)
    #expect(keychain.saveCredentialCallCount == 1)
    #expect(keychain.lastSavedCredential?.credential == secret)
    #expect(keychain.lastSavedCredential?.serverID == serverID)
    #expect(keychain.storedCredentials[serverID.uuidString] == secret)
    expectNoSuiteWrites("during save")

    #expect(try storage.readCredential(for: serverID) == secret)
    expectNoSuiteWrites("during a successful read")

    try storage.deleteCredential(for: serverID)
    #expect(keychain.deleteCredentialCallCount == 1)
    #expect(keychain.lastDeletedServerID == serverID)
    #expect(try storage.readCredential(for: serverID) == nil)
    expectNoSuiteWrites("during delete")
  }

  @Test("credential errors propagate with identity preserved")
  func credentialErrorsPropagate() {
    let keychain = MockKeychainManager()
    let original = AppStorageTestError("keychain-failure")
    keychain.errorStub = original
    let sharedData = TestDefaults.makeNamedSuite()
    let storage = ConcreteAppStorage(
      sharedDataSuite: sharedData.suite,
      appLocalSuite: TestDefaults.makeSuite(),
      keychain: keychain
    )
    let serverID = UUID()

    let readError = #expect(throws: AppStorageTestError.self) {
      _ = try storage.readCredential(for: serverID)
    }
    #expect(readError === original)

    let saveError = #expect(throws: AppStorageTestError.self) {
      try storage.saveCredential("value", for: serverID)
    }
    #expect(saveError === original)

    let deleteError = #expect(throws: AppStorageTestError.self) {
      try storage.deleteCredential(for: serverID)
    }
    #expect(deleteError === original)
  }
}
