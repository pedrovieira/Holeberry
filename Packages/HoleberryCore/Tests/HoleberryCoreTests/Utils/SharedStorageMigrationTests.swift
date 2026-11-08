import Defaults
import Foundation
import Testing

@testable import HoleberryCore

private struct SharedStorageTestError: Error, Equatable {}

@Suite("SharedAppStorage")
@MainActor
struct SharedAppStorageTests {
  @Test func configurationReadsRequiredInfoValues() throws {
    let configuration = try SharedAppStorageConfiguration(infoDictionary: [
      SharedAppStorage.appGroupIdentifierInfoKey: "group.me.example.tests",
      SharedAppStorage.keychainAccessGroupInfoKey: "TEAMID.me.example.tests.shared"
    ])

    #expect(configuration.appGroupIdentifier == "group.me.example.tests")
    #expect(configuration.keychainAccessGroup == "TEAMID.me.example.tests.shared")
  }

  @Test func missingAppGroupValueThrows() {
    #expect(
      throws: SharedAppStorageError.missingInfoValue(SharedAppStorage.appGroupIdentifierInfoKey)
    ) {
      try SharedAppStorageConfiguration(infoDictionary: [
        SharedAppStorage.keychainAccessGroupInfoKey: "TEAMID.me.example.tests.shared"
      ])
    }
  }

  @Test func missingKeychainGroupValueThrows() {
    #expect(
      throws: SharedAppStorageError.missingInfoValue(SharedAppStorage.keychainAccessGroupInfoKey)
    ) {
      try SharedAppStorageConfiguration(infoDictionary: [
        SharedAppStorage.appGroupIdentifierInfoKey: "group.me.example.tests"
      ])
    }
  }

  @Test func unresolvedBuildSubstitutionThrows() {
    #expect(
      throws: SharedAppStorageError.invalidInfoValue(SharedAppStorage.keychainAccessGroupInfoKey)
    ) {
      try SharedAppStorageConfiguration(infoDictionary: [
        SharedAppStorage.appGroupIdentifierInfoKey: "group.me.example.tests",
        SharedAppStorage.keychainAccessGroupInfoKey: "$(AppIdentifierPrefix)me.example.tests.shared"
      ])
    }
  }

  @Test func nonGroupAppGroupIdentifierThrows() {
    #expect(
      throws: SharedAppStorageError.invalidInfoValue(SharedAppStorage.appGroupIdentifierInfoKey)
    ) {
      try SharedAppStorageConfiguration(infoDictionary: [
        SharedAppStorage.appGroupIdentifierInfoKey: "me.example.tests",
        SharedAppStorage.keychainAccessGroupInfoKey: "TEAMID.me.example.tests.shared"
      ])
    }
  }

  @Test func publicResolverThrowsWhenGroupContainerIsUnavailable() throws {
    let group = "group.me.example.\(UUID().uuidString)"
    let bundle = try makeBundle(info: [
      SharedAppStorage.appGroupIdentifierInfoKey: group,
      SharedAppStorage.keychainAccessGroupInfoKey: "TEAMID.me.example.tests.shared"
    ])

    #expect(throws: SharedAppStorageError.unavailableAppGroupContainer(group)) {
      _ = try SharedAppStorage(bundle: bundle)
    }
  }

  @Test func injectedGroupStorageExposesSuiteAndContainer() throws {
    let suite = TestDefaults.makeSuite()
    let containerURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("HoleberrySharedStorageTests-\(UUID().uuidString)", isDirectory: true)
    let configuration = SharedAppStorageConfiguration(
      appGroupIdentifier: "group.me.example.tests",
      keychainAccessGroup: "TEAMID.me.example.tests.shared"
    )

    let storage = SharedAppStorage(
      configuration: configuration,
      suite: suite,
      containerURL: containerURL
    )

    #expect(storage.configuration == configuration)
    #expect(storage.suite === suite)
    #expect(storage.containerURL == containerURL)
  }

  private func makeBundle(info: [String: Any]) throws -> Bundle {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("HoleberryFakeBundle-\(UUID().uuidString).bundle", isDirectory: true)
    let contents = root.appendingPathComponent("Contents", isDirectory: true)
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)

    var plist: [String: Any] = [
      "CFBundleIdentifier": "me.example.tests.fake",
      "CFBundleName": "Fake",
      "CFBundlePackageType": "BNDL"
    ]
    plist.merge(info) { _, new in new }
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try data.write(to: contents.appendingPathComponent("Info.plist"))
    return try #require(Bundle(url: root))
  }
}

@Suite("KeychainManager options")
@MainActor
struct KeychainManagerOptionsTests {
  @Test func defaultInitializationPreservesLegacyConfiguration() {
    let keychain = KeychainManager()

    #expect(keychain.service == (Bundle.main.bundleIdentifier ?? "me.pedrovieira.holeberry"))
    #expect(keychain.accessGroup == nil)
    #expect(keychain.usesDataProtectionKeychain == false)
    #expect(keychain.isInteractive)
  }

  @Test func sharedFactorySelectsDataProtectionKeychain() {
    let keychain = KeychainManager.shared(accessGroup: "TEAMID.me.example.tests.shared", interactive: false)

    #expect(keychain.service == KeychainManager.sharedService)
    #expect(keychain.accessGroup == "TEAMID.me.example.tests.shared")
    #expect(keychain.usesDataProtectionKeychain)
    #expect(keychain.isInteractive == false)
  }
}

@Suite("SharedCredentialKeychain")
@MainActor
struct SharedCredentialKeychainTests {
  @Test func savesAndReadsOnlyTheSharedStore() throws {
    let shared = MockKeychainManager()
    let legacy = MockKeychainManager()
    let id = UUID()
    let keychain = SharedCredentialKeychain(shared: shared, legacy: legacy)

    try keychain.saveCredential("shared-secret", for: id)

    #expect(try keychain.readCredential(for: id) == "shared-secret")
    #expect(shared.storedCredentials[id.uuidString] == "shared-secret")
    #expect(legacy.storedCredentials[id.uuidString] == nil)
  }

  @Test func explicitDeletionClearsSharedAndRetainedLegacyItems() throws {
    let shared = MockKeychainManager()
    let legacy = MockKeychainManager()
    let id = UUID()
    try shared.saveCredential("shared-secret", for: id)
    try legacy.saveCredential("legacy-secret", for: id)
    let keychain = SharedCredentialKeychain(shared: shared, legacy: legacy)

    try keychain.deleteCredential(for: id)

    #expect(try shared.readCredential(for: id) == nil)
    #expect(try legacy.readCredential(for: id) == nil)
  }

  @Test func readsNeverFallBackToLegacyAfterDeletion() throws {
    let shared = MockKeychainManager()
    let legacy = MockKeychainManager()
    let id = UUID()
    try shared.saveCredential("shared-secret", for: id)
    try legacy.saveCredential("legacy-secret", for: id)
    let keychain = SharedCredentialKeychain(shared: shared, legacy: legacy)

    try keychain.deleteCredential(for: id)
    try legacy.saveCredential("resurrected-secret", for: id)

    #expect(try keychain.readCredential(for: id) == nil)
  }

  @Test func sharedDeletionFailureStillAttemptsLegacyCleanup() throws {
    let shared = MockKeychainManager()
    let legacy = MockKeychainManager()
    let id = UUID()
    try shared.saveCredential("shared-secret", for: id)
    try legacy.saveCredential("legacy-secret", for: id)
    shared.deleteErrorStub = SharedStorageTestError()
    let keychain = SharedCredentialKeychain(shared: shared, legacy: legacy)

    #expect(throws: SharedStorageTestError.self) {
      try keychain.deleteCredential(for: id)
    }

    #expect(shared.storedCredentials[id.uuidString] == "shared-secret")
    #expect(legacy.storedCredentials[id.uuidString] == nil)
  }

  @Test func legacyDeletionFailureAfterSharedSuccessDoesNotExposeLegacy() throws {
    let shared = MockKeychainManager()
    let legacy = MockKeychainManager()
    let id = UUID()
    try shared.saveCredential("shared-secret", for: id)
    try legacy.saveCredential("legacy-secret", for: id)
    legacy.deleteErrorStub = SharedStorageTestError()
    let keychain = SharedCredentialKeychain(shared: shared, legacy: legacy)

    #expect(throws: SharedStorageTestError.self) {
      try keychain.deleteCredential(for: id)
    }

    #expect(shared.storedCredentials[id.uuidString] == nil)
    #expect(legacy.storedCredentials[id.uuidString] == "legacy-secret")
    #expect(try keychain.readCredential(for: id) == nil)
  }
}

@Suite("SharedStorageMigration")
@MainActor
struct SharedStorageMigrationTests {
  @Test func copiesEveryServerConfigField() throws {
    let harness = makeHarness()
    let first = ServerConfig(
      id: UUID(),
      label: "Primary",
      icon: "house",
      url: "https://pihole.example:8443",
      version: .v6
    )
    let second = ServerConfig(id: UUID(), url: "http://backup.local", version: .v5)
    Defaults[.servers(suite: harness.legacySuite)] = [first, second]

    try harness.migration.migrate()

    let shared = Defaults[.servers(suite: harness.sharedSuite)]
    #expect(shared.count == 2)
    #expect(shared[0].id == first.id)
    #expect(shared[0].label == "Primary")
    #expect(shared[0].icon == "house")
    #expect(shared[0].url == "https://pihole.example:8443")
    #expect(shared[0].version == .v6)
    #expect(shared[1].id == second.id)
    #expect(shared[1].label == nil)
    #expect(shared[1].icon == nil)
    #expect(shared[1].url == "http://backup.local")
    #expect(shared[1].version == .v5)
    #expect(
      Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] == SharedStorageMigration.currentVersion)
    #expect(Defaults[.servers(suite: harness.legacySuite)].count == 2)
  }

  @Test func copiesTemporaryUnblockRecordsExactly() throws {
    let harness = makeHarness()
    let first = ServerConfig(id: UUID(), url: "http://first.local", version: .v6)
    let second = ServerConfig(id: UUID(), url: "http://second.local", version: .v6)
    let firstRecords = [
      TempUnblockRecord(
        domain: "ads.example",
        uuid: UUID().uuidString,
        startDateUTC: Date(timeIntervalSince1970: 1_000),
        durationSeconds: 300,
        pendingRemoval: true,
        retryCount: 3
      ),
      TempUnblockRecord(
        domain: "tracker.example",
        uuid: UUID().uuidString,
        startDateUTC: Date(timeIntervalSince1970: 2_000),
        durationSeconds: 900
      )
    ]
    let secondRecords = [
      TempUnblockRecord(
        domain: "media.example",
        uuid: UUID().uuidString,
        startDateUTC: Date(timeIntervalSince1970: 3_000),
        durationSeconds: 60,
        pendingRemoval: true,
        retryCount: 1
      )
    ]
    Defaults[.servers(suite: harness.legacySuite)] = [first, second]
    Defaults[.tempUnblocks(for: first.id, suite: harness.legacySuite)] = firstRecords
    Defaults[.tempUnblocks(for: second.id, suite: harness.legacySuite)] = secondRecords

    try harness.migration.migrate()

    #expect(Defaults[.tempUnblocks(for: first.id, suite: harness.sharedSuite)] == firstRecords)
    #expect(Defaults[.tempUnblocks(for: second.id, suite: harness.sharedSuite)] == secondRecords)
    #expect(Defaults[.tempUnblocks(for: first.id, suite: harness.legacySuite)] == firstRecords)
    #expect(Defaults[.tempUnblocks(for: second.id, suite: harness.legacySuite)] == secondRecords)
  }

  @Test func copiesCredentialAndVerifiesReadback() throws {
    let harness = makeHarness()
    let server = ServerConfig(id: UUID(), url: "http://pihole.local", version: .v6)
    Defaults[.servers(suite: harness.legacySuite)] = [server]
    try harness.legacyKeychain.saveCredential("legacy-secret", for: server.id)

    try harness.migration.migrate()

    #expect(try harness.sharedKeychain.readCredential(for: server.id) == "legacy-secret")
    #expect(try harness.legacyKeychain.readCredential(for: server.id) == "legacy-secret")
    #expect(
      Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] == SharedStorageMigration.currentVersion)
  }

  @Test func passwordlessServerRemovesPriorPartialSharedCredential() throws {
    let harness = makeHarness()
    let server = ServerConfig(id: UUID(), url: "http://pihole.local", version: .v6)
    Defaults[.servers(suite: harness.legacySuite)] = [server]
    try harness.sharedKeychain.saveCredential("partial-secret", for: server.id)

    try harness.migration.migrate()

    #expect(try harness.sharedKeychain.readCredential(for: server.id) == nil)
    #expect(try harness.legacyKeychain.readCredential(for: server.id) == nil)
    #expect(
      Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] == SharedStorageMigration.currentVersion)
  }

  @Test func emptyConfigurationCompletesAndNeverResurrectsLaterLegacyServers() throws {
    let harness = makeHarness()

    try harness.migration.migrate()

    #expect(Defaults[.servers(suite: harness.sharedSuite)].isEmpty)
    #expect(
      Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] == SharedStorageMigration.currentVersion)
    #expect(harness.legacyKeychain.readCallCount == 0)

    let late = ServerConfig(id: UUID(), url: "http://late.local", version: .v6)
    Defaults[.servers(suite: harness.legacySuite)] = [late]
    try harness.legacyKeychain.saveCredential("late-secret", for: late.id)

    try harness.migration.migrate()

    #expect(Defaults[.servers(suite: harness.sharedSuite)].isEmpty)
    #expect(try harness.sharedKeychain.readCredential(for: late.id) == nil)
    #expect(harness.legacyKeychain.readCallCount == 0)
  }

  @Test func sourceCredentialReadFailurePreventsCompletion() throws {
    let harness = makeHarness()
    let server = ServerConfig(id: UUID(), url: "http://pihole.local", version: .v6)
    Defaults[.servers(suite: harness.legacySuite)] = [server]
    harness.legacyKeychain.readErrorStub = SharedStorageTestError()

    #expect(throws: SharedStorageTestError.self) {
      try harness.migration.migrate()
    }

    #expect(Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] == 0)
    #expect(Defaults[.servers(suite: harness.legacySuite)].count == 1)
  }

  @Test func targetCredentialWriteFailurePreventsCompletion() throws {
    let harness = makeHarness()
    let server = ServerConfig(id: UUID(), url: "http://pihole.local", version: .v6)
    Defaults[.servers(suite: harness.legacySuite)] = [server]
    try harness.legacyKeychain.saveCredential("legacy-secret", for: server.id)
    harness.sharedKeychain.saveErrorStub = SharedStorageTestError()

    #expect(throws: SharedStorageTestError.self) {
      try harness.migration.migrate()
    }

    #expect(Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] == 0)
    #expect(try harness.legacyKeychain.readCredential(for: server.id) == "legacy-secret")
  }

  @Test func credentialReadbackMismatchPreventsCompletion() throws {
    let harness = makeHarness()
    let server = ServerConfig(id: UUID(), url: "http://pihole.local", version: .v6)
    Defaults[.servers(suite: harness.legacySuite)] = [server]
    try harness.legacyKeychain.saveCredential("legacy-secret", for: server.id)
    harness.sharedKeychain.readResultOverride = .success("different-secret")

    #expect(throws: SharedStorageMigrationError.credentialReadbackMismatch(server.id)) {
      try harness.migration.migrate()
    }

    #expect(Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] == 0)
  }

  @Test func retryUsesCurrentLegacyFieldsAndCredential() throws {
    let harness = makeHarness()
    let id = UUID()
    let initial = ServerConfig(
      id: id,
      label: "Old",
      icon: "old",
      url: "http://old.local",
      version: .v6
    )
    Defaults[.servers(suite: harness.legacySuite)] = [initial]
    try harness.legacyKeychain.saveCredential("old-secret", for: id)
    harness.sharedKeychain.saveErrorStub = SharedStorageTestError()

    #expect(throws: SharedStorageTestError.self) {
      try harness.migration.migrate()
    }
    #expect(Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] == 0)

    harness.sharedKeychain.saveErrorStub = nil
    let updated = ServerConfig(
      id: id,
      label: "New",
      icon: "new",
      url: "https://new.local",
      version: .v5
    )
    Defaults[.servers(suite: harness.legacySuite)] = [updated]
    try harness.legacyKeychain.saveCredential("new-secret", for: id)

    try harness.migration.migrate()

    let shared = Defaults[.servers(suite: harness.sharedSuite)]
    #expect(shared.count == 1)
    #expect(shared[0].label == "New")
    #expect(shared[0].icon == "new")
    #expect(shared[0].url == "https://new.local")
    #expect(shared[0].version == .v5)
    #expect(try harness.sharedKeychain.readCredential(for: id) == "new-secret")
    #expect(
      Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] == SharedStorageMigration.currentVersion)
  }

  @Test func staleSharedServersFromPartialAttemptAreCleaned() throws {
    let harness = makeHarness()
    let kept = ServerConfig(id: UUID(), url: "http://kept.local", version: .v6)
    let removed = ServerConfig(id: UUID(), url: "http://removed.local", version: .v6)
    let staleRecord = TempUnblockRecord(
      domain: "stale.example",
      uuid: UUID().uuidString,
      startDateUTC: Date(timeIntervalSince1970: 1_000),
      durationSeconds: 300
    )
    Defaults[.servers(suite: harness.legacySuite)] = [kept]
    Defaults[.servers(suite: harness.sharedSuite)] = [kept, removed]
    Defaults[.tempUnblocks(for: removed.id, suite: harness.sharedSuite)] = [staleRecord]
    try harness.sharedKeychain.saveCredential("stale-secret", for: removed.id)

    try harness.migration.migrate()

    let shared = Defaults[.servers(suite: harness.sharedSuite)]
    #expect(shared.count == 1)
    #expect(shared[0].id == kept.id)
    #expect(shared[0].url == "http://kept.local")
    #expect(Defaults[.tempUnblocks(for: removed.id, suite: harness.sharedSuite)].isEmpty)
    #expect(try harness.sharedKeychain.readCredential(for: removed.id) == nil)
    #expect(
      Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] == SharedStorageMigration.currentVersion)
  }

  @Test func completedMigrationDoesNotConsultLegacyOnLaterFailures() throws {
    let harness = makeHarness()
    let server = ServerConfig(id: UUID(), url: "http://pihole.local", version: .v6)
    Defaults[.servers(suite: harness.legacySuite)] = [server]
    try harness.legacyKeychain.saveCredential("legacy-secret", for: server.id)

    try harness.migration.migrate()
    let legacyReadsAfterMigration = harness.legacyKeychain.readCallCount
    harness.legacyKeychain.readErrorStub = SharedStorageTestError()

    try harness.migration.migrate()

    #expect(harness.legacyKeychain.readCallCount == legacyReadsAfterMigration)
    #expect(Defaults[.servers(suite: harness.sharedSuite)].count == 1)
    #expect(
      Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] == SharedStorageMigration.currentVersion)
  }

  @Test func malformedLegacyServersPreventCompletionAndPreserveRawData() throws {
    let harness = makeHarness()
    let key = Defaults.Keys.servers(suite: harness.legacySuite)
    let malformed: [String] = ["not-json"]
    setRawDefaultsValue(malformed, for: key)

    #expect(throws: SharedStorageMigrationError.malformedLegacyConfiguration) {
      try harness.migration.migrate()
    }

    #expect(Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] == 0)
    #expect(rawDefaultsValue(for: key) as? [String] == malformed)
    #expect(Defaults[.servers(suite: harness.sharedSuite)].isEmpty)

    let server = ServerConfig(id: UUID(), url: "http://pihole.local", version: .v6)
    Defaults[.servers(suite: harness.legacySuite)] = [server]

    try harness.migration.migrate()

    #expect(Defaults[.servers(suite: harness.sharedSuite)].count == 1)
    #expect(
      Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] == SharedStorageMigration.currentVersion)
  }

  @Test func malformedLegacyTemporaryRecordsPreventCompletionAndPreserveRawData() throws {
    let harness = makeHarness()
    let server = ServerConfig(id: UUID(), url: "http://pihole.local", version: .v6)
    Defaults[.servers(suite: harness.legacySuite)] = [server]
    let key = Defaults.Keys.tempUnblocks(for: server.id, suite: harness.legacySuite)
    let malformed: [String] = ["not-json"]
    setRawDefaultsValue(malformed, for: key)

    #expect(throws: SharedStorageMigrationError.malformedLegacyTemporaryRecords(server.id)) {
      try harness.migration.migrate()
    }

    #expect(Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] == 0)
    #expect(rawDefaultsValue(for: key) as? [String] == malformed)
    #expect(Defaults[.servers(suite: harness.sharedSuite)].isEmpty)

    let records = [
      TempUnblockRecord(
        domain: "ads.example",
        uuid: UUID().uuidString,
        startDateUTC: Date(timeIntervalSince1970: 1_000),
        durationSeconds: 300,
        pendingRemoval: true,
        retryCount: 2
      )
    ]
    Defaults[.tempUnblocks(for: server.id, suite: harness.legacySuite)] = records

    try harness.migration.migrate()

    #expect(Defaults[.tempUnblocks(for: server.id, suite: harness.sharedSuite)] == records)
    #expect(
      Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] == SharedStorageMigration.currentVersion)
  }

  @Test func explicitEmptyServerArrayMigratesNormally() throws {
    let harness = makeHarness()
    Defaults[.servers(suite: harness.legacySuite)] = []

    try harness.migration.migrate()

    #expect(Defaults[.servers(suite: harness.sharedSuite)].isEmpty)
    #expect(
      Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] == SharedStorageMigration.currentVersion)
  }

  @Test func explicitEmptyTemporaryRecordsArrayMigratesNormally() throws {
    let harness = makeHarness()
    let server = ServerConfig(id: UUID(), url: "http://pihole.local", version: .v6)
    Defaults[.servers(suite: harness.legacySuite)] = [server]
    Defaults[.tempUnblocks(for: server.id, suite: harness.legacySuite)] = []

    try harness.migration.migrate()

    #expect(Defaults[.tempUnblocks(for: server.id, suite: harness.sharedSuite)].isEmpty)
    #expect(
      Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] == SharedStorageMigration.currentVersion)
  }

  @Test func synchronizationFailureDoesNotBlockCompletedMigration() throws {
    let sharedSuite = TestUserDefaults()
    sharedSuite.synchronizeResult = false
    let harness = makeHarness(sharedSuite: sharedSuite)
    let server = ServerConfig(id: UUID(), url: "http://pihole.local", version: .v6)
    let records = [
      TempUnblockRecord(
        domain: "ads.example",
        uuid: UUID().uuidString,
        startDateUTC: Date(timeIntervalSince1970: 1_000),
        durationSeconds: 300
      )
    ]
    Defaults[.servers(suite: harness.legacySuite)] = [server]
    Defaults[.tempUnblocks(for: server.id, suite: harness.legacySuite)] = records
    try harness.legacyKeychain.saveCredential("legacy-secret", for: server.id)

    #expect(sharedSuite.synchronize() == false)

    try harness.migration.migrate()

    #expect(Defaults[.servers(suite: sharedSuite)].map(\.id) == [server.id])
    #expect(Defaults[.tempUnblocks(for: server.id, suite: sharedSuite)] == records)
    #expect(try harness.sharedKeychain.readCredential(for: server.id) == "legacy-secret")
    #expect(
      Defaults[.sharedStorageMigrationVersion(suite: sharedSuite)] == SharedStorageMigration.currentVersion)
  }

  @Test func sharedConfigurationWriteRejectionPreventsCompletion() throws {
    let sharedSuite = TestUserDefaults()
    sharedSuite.rejectedWriteKeys = [Defaults.Keys.servers(suite: sharedSuite).name]
    let harness = makeHarness(sharedSuite: sharedSuite)
    let server = ServerConfig(id: UUID(), url: "http://pihole.local", version: .v6)
    Defaults[.servers(suite: harness.legacySuite)] = [server]

    #expect(throws: SharedStorageMigrationError.configurationReadbackMismatch) {
      try harness.migration.migrate()
    }

    #expect(Defaults[.sharedStorageMigrationVersion(suite: sharedSuite)] == 0)
  }

  @Test func sharedTemporaryRecordsWriteRejectionPreventsCompletion() throws {
    let sharedSuite = TestUserDefaults()
    let server = ServerConfig(id: UUID(), url: "http://pihole.local", version: .v6)
    let records = [
      TempUnblockRecord(
        domain: "ads.example",
        uuid: UUID().uuidString,
        startDateUTC: Date(timeIntervalSince1970: 1_000),
        durationSeconds: 300
      )
    ]
    sharedSuite.rejectedWriteKeys = [Defaults.Keys.tempUnblocks(for: server.id, suite: sharedSuite).name]
    let harness = makeHarness(sharedSuite: sharedSuite)
    Defaults[.servers(suite: harness.legacySuite)] = [server]
    Defaults[.tempUnblocks(for: server.id, suite: harness.legacySuite)] = records

    #expect(throws: SharedStorageMigrationError.temporaryRecordsReadbackMismatch(server.id)) {
      try harness.migration.migrate()
    }

    #expect(Defaults[.sharedStorageMigrationVersion(suite: sharedSuite)] == 0)
  }

  @Test func sharedCompletionMarkerWriteRejectionPreventsCompletion() throws {
    let sharedSuite = TestUserDefaults()
    sharedSuite.rejectedWriteKeys = [Defaults.Keys.sharedStorageMigrationVersion(suite: sharedSuite).name]
    let harness = makeHarness(sharedSuite: sharedSuite)
    let server = ServerConfig(id: UUID(), url: "http://pihole.local", version: .v6)
    Defaults[.servers(suite: harness.legacySuite)] = [server]
    try harness.legacyKeychain.saveCredential("legacy-secret", for: server.id)

    #expect(throws: SharedStorageMigrationError.completionMarkerNotPersisted) {
      try harness.migration.migrate()
    }

    #expect(Defaults[.sharedStorageMigrationVersion(suite: sharedSuite)] == 0)
  }

  private struct Harness {
    let legacySuite: UserDefaults
    let sharedSuite: UserDefaults
    let legacyKeychain: MockKeychainManager
    let sharedKeychain: MockKeychainManager
    let migration: SharedStorageMigration
  }

  private func makeHarness(
    legacySuite: UserDefaults = TestDefaults.makeSuite(),
    sharedSuite: UserDefaults = TestDefaults.makeSuite()
  ) -> Harness {
    let legacyKeychain = MockKeychainManager()
    let sharedKeychain = MockKeychainManager()
    return Harness(
      legacySuite: legacySuite,
      sharedSuite: sharedSuite,
      legacyKeychain: legacyKeychain,
      sharedKeychain: sharedKeychain,
      migration: SharedStorageMigration(
        legacySuite: legacySuite,
        sharedSuite: sharedSuite,
        legacyKeychain: legacyKeychain,
        sharedKeychain: sharedKeychain
      )
    )
  }
}
