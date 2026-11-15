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

  private func containsStringValue(_ needle: String, in suite: UserDefaults) -> Bool {
    String(describing: suite.dictionaryRepresentation()).contains(needle)
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
  func saveUsesExistingKeys() {
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
      sharedDataSuite: sharedDataSuite, appLocalSuite: appLocalSuite, keychain: keychain)

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

  // MARK: - Credentials

  @Test("credential roundtrip goes only to the injected keychain")
  func credentialRoundtrip() throws {
    let sharedDataSuite = TestDefaults.makeSuite()
    let appLocalSuite = TestDefaults.makeSuite()
    let keychain = MockKeychainManager()
    let storage = ConcreteAppStorage(
      sharedDataSuite: sharedDataSuite, appLocalSuite: appLocalSuite, keychain: keychain)
    let serverID = UUID()
    let secret = "super-secret-token"

    #expect(try storage.readCredential(for: serverID) == nil)
    #expect(keychain.readCredentialCallCount == 1)
    #expect(keychain.lastReadServerID == serverID)

    try storage.saveCredential(secret, for: serverID)
    #expect(keychain.saveCredentialCallCount == 1)
    #expect(keychain.lastSavedCredential?.credential == secret)
    #expect(keychain.lastSavedCredential?.serverID == serverID)
    #expect(keychain.storedCredentials[serverID.uuidString] == secret)
    #expect(try storage.readCredential(for: serverID) == secret)

    try storage.deleteCredential(for: serverID)
    #expect(keychain.deleteCredentialCallCount == 1)
    #expect(keychain.lastDeletedServerID == serverID)
    #expect(try storage.readCredential(for: serverID) == nil)

    // Credentials never enter either defaults suite.
    #expect(!containsStringValue(secret, in: sharedDataSuite))
    #expect(!containsStringValue(secret, in: appLocalSuite))
  }

  @Test("credential errors propagate with identity preserved")
  func credentialErrorsPropagate() {
    let keychain = MockKeychainManager()
    let original = AppStorageTestError("keychain-failure")
    keychain.errorStub = original
    let storage = ConcreteAppStorage(
      sharedDataSuite: TestDefaults.makeSuite(),
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
