import Defaults
import Foundation
import Testing

@testable import HoleberryCore

private struct SharedStorageTestError: Error, Equatable {}

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

@Suite("Defaults target verification")
@MainActor
struct DefaultsTargetVerificationTests {
  @Test func registeredFallbackIsNotAPersistedValue() {
    let (name, suite) = TestDefaults.makeNamedSuite()
    let key = Defaults.Keys.servers(suite: suite)

    #expect(suite.object(forKey: key.name) != nil)
    #expect(suite.persistentDomain(forName: name)?[key.name] == nil)
    #expect(throws: DefaultsValueValidationError.missingPersistedValue(key.name)) {
      try Defaults.Keys.strictlyDecodedPersistedArray(key, suiteName: name)
    }
  }

  @Test func explicitlySavedEmptyArrayIsPersisted() throws {
    let (name, suite) = TestDefaults.makeNamedSuite()
    let key = Defaults.Keys.servers(suite: suite)

    Defaults[key] = []

    #expect(try Defaults.Keys.strictlyDecodedPersistedArray(key, suiteName: name) == [])
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

  @Test func malformedLegacyServersStartFreshAndPreserveLegacyData() throws {
    let harness = makeHarness()
    let key = Defaults.Keys.servers(suite: harness.legacySuite)
    let malformed: [String] = ["not-json"]
    setRawDefaultsValue(malformed, for: key)

    try harness.migration.migrate()

    #expect(Defaults[.servers(suite: harness.sharedSuite)].isEmpty)
    #expect(
      Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] == SharedStorageMigration.currentVersion)
    #expect(rawDefaultsValue(for: key) as? [String] == malformed)
    #expect(harness.legacyKeychain.readCallCount == 0)

    let late = ServerConfig(id: UUID(), url: "http://late.local", version: .v6)
    Defaults[.servers(suite: harness.legacySuite)] = [late]
    try harness.legacyKeychain.saveCredential("late-secret", for: late.id)

    try harness.migration.migrate()

    #expect(Defaults[.servers(suite: harness.sharedSuite)].isEmpty)
    #expect(try harness.sharedKeychain.readCredential(for: late.id) == nil)
    #expect(harness.legacyKeychain.readCallCount == 0)
  }

  @Test func malformedLegacyTemporaryRecordsStartFreshAndPreserveLegacyData() throws {
    let harness = makeHarness()
    let server = ServerConfig(id: UUID(), url: "http://pihole.local", version: .v6)
    Defaults[.servers(suite: harness.legacySuite)] = [server]
    let key = Defaults.Keys.tempUnblocks(for: server.id, suite: harness.legacySuite)
    let malformed: [String] = ["not-json"]
    setRawDefaultsValue(malformed, for: key)

    try harness.migration.migrate()

    #expect(Defaults[.servers(suite: harness.sharedSuite)].isEmpty)
    #expect(Defaults[.tempUnblocks(for: server.id, suite: harness.sharedSuite)].isEmpty)
    #expect(
      Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] == SharedStorageMigration.currentVersion)
    #expect(rawDefaultsValue(for: key) as? [String] == malformed)
    #expect(Defaults[.servers(suite: harness.legacySuite)].map(\.id) == [server.id])
  }

  @Test func sourceCredentialReadFailureStartsFreshAndCompletes() throws {
    let harness = makeHarness()
    let server = ServerConfig(id: UUID(), url: "http://pihole.local", version: .v6)
    Defaults[.servers(suite: harness.legacySuite)] = [server]
    try harness.legacyKeychain.saveCredential("legacy-secret", for: server.id)
    harness.legacyKeychain.readErrorStub = SharedStorageTestError()

    try harness.migration.migrate()

    #expect(Defaults[.servers(suite: harness.sharedSuite)].isEmpty)
    #expect(
      Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] == SharedStorageMigration.currentVersion)
    #expect(Defaults[.servers(suite: harness.legacySuite)].map(\.id) == [server.id])
    #expect(harness.legacyKeychain.storedCredentials[server.id.uuidString] == "legacy-secret")
  }

  @Test func targetCredentialWriteFailureStartsFreshAndCompletes() throws {
    let harness = makeHarness()
    let server = ServerConfig(id: UUID(), url: "http://pihole.local", version: .v6)
    Defaults[.servers(suite: harness.legacySuite)] = [server]
    try harness.legacyKeychain.saveCredential("legacy-secret", for: server.id)
    harness.sharedKeychain.saveErrorStub = SharedStorageTestError()

    try harness.migration.migrate()

    #expect(Defaults[.servers(suite: harness.sharedSuite)].isEmpty)
    #expect(
      Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] == SharedStorageMigration.currentVersion)
    #expect(try harness.legacyKeychain.readCredential(for: server.id) == "legacy-secret")
  }

  @Test func credentialReadbackMismatchStartsFreshAndCompletes() throws {
    let harness = makeHarness()
    let server = ServerConfig(id: UUID(), url: "http://pihole.local", version: .v6)
    Defaults[.servers(suite: harness.legacySuite)] = [server]
    try harness.legacyKeychain.saveCredential("legacy-secret", for: server.id)
    harness.sharedKeychain.readResultOverride = .success("different-secret")

    try harness.migration.migrate()

    #expect(Defaults[.servers(suite: harness.sharedSuite)].isEmpty)
    #expect(try harness.sharedKeychain.readCredential(for: server.id) == nil)
    #expect(
      Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] == SharedStorageMigration.currentVersion)
    #expect(try harness.legacyKeychain.readCredential(for: server.id) == "legacy-secret")
  }

  @Test func partialImportFailureLeavesNoPartialServersOrCredentials() throws {
    let harness = makeHarness()
    let first = ServerConfig(id: UUID(), url: "http://first.local", version: .v6)
    let second = ServerConfig(id: UUID(), url: "http://second.local", version: .v6)
    let record = TempUnblockRecord(
      domain: "ads.example",
      uuid: UUID().uuidString,
      startDateUTC: Date(timeIntervalSince1970: 1_000),
      durationSeconds: 300
    )
    Defaults[.servers(suite: harness.legacySuite)] = [first, second]
    Defaults[.tempUnblocks(for: first.id, suite: harness.legacySuite)] = [record]
    Defaults[.tempUnblocks(for: second.id, suite: harness.legacySuite)] = [record]
    try harness.legacyKeychain.saveCredential("first-secret", for: first.id)
    try harness.legacyKeychain.saveCredential("second-secret", for: second.id)
    harness.sharedKeychain.saveErrorsByServerID[second.id] = SharedStorageTestError()

    try harness.migration.migrate()

    #expect(Defaults[.servers(suite: harness.sharedSuite)].isEmpty)
    #expect(Defaults[.tempUnblocks(for: first.id, suite: harness.sharedSuite)].isEmpty)
    #expect(Defaults[.tempUnblocks(for: second.id, suite: harness.sharedSuite)].isEmpty)
    #expect(try harness.sharedKeychain.readCredential(for: first.id) == nil)
    #expect(try harness.sharedKeychain.readCredential(for: second.id) == nil)
    #expect(
      Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] == SharedStorageMigration.currentVersion)
    #expect(Defaults[.servers(suite: harness.legacySuite)].map(\.id) == [first.id, second.id])
    #expect(Defaults[.tempUnblocks(for: first.id, suite: harness.legacySuite)] == [record])
    #expect(Defaults[.tempUnblocks(for: second.id, suite: harness.legacySuite)] == [record])
    #expect(try harness.legacyKeychain.readCredential(for: first.id) == "first-secret")
  }

  @Test func freshStartDecisionIsNotRepeatedOnNextMigration() throws {
    let harness = makeHarness()
    setRawDefaultsValue(["not-json"], for: Defaults.Keys.servers(suite: harness.legacySuite))

    try harness.migration.migrate()
    let legacyReadsAfterFreshStart = harness.legacyKeychain.readCallCount

    let late = ServerConfig(id: UUID(), url: "http://late.local", version: .v6)
    Defaults[.servers(suite: harness.legacySuite)] = [late]
    try harness.legacyKeychain.saveCredential("late-secret", for: late.id)

    try harness.migration.migrate()

    #expect(harness.legacyKeychain.readCallCount == legacyReadsAfterFreshStart)
    #expect(Defaults[.servers(suite: harness.sharedSuite)].isEmpty)
    #expect(try harness.sharedKeychain.readCredential(for: late.id) == nil)
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

  @Test func completedMigrationDoesNotConsultLegacy() throws {
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

  @Test func completedMigrationKeepsExistingSharedConfiguration() throws {
    let harness = makeHarness()
    let legacy = ServerConfig(id: UUID(), url: "http://legacy.local", version: .v5)
    let shared = ServerConfig(id: UUID(), url: "http://shared.local", version: .v6)
    Defaults[.servers(suite: harness.legacySuite)] = [legacy]
    Defaults[.servers(suite: harness.sharedSuite)] = [shared]
    Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] = SharedStorageMigration.currentVersion

    try harness.migration.migrate()

    let current = Defaults[.servers(suite: harness.sharedSuite)]
    #expect(current.count == 1)
    #expect(current[0].id == shared.id)
    #expect(current[0].url == "http://shared.local")
    #expect(current[0].version == .v6)
    #expect(Defaults[.servers(suite: harness.legacySuite)].map(\.id) == [legacy.id])
    #expect(harness.legacyKeychain.readCallCount == 0)
  }

  @Test func activationRecordsCurrentVersionInLegacySuite() {
    let suite = TestDefaults.makeSuite()

    #expect(SharedStorageMigration.isCurrentVersionActivated(in: suite) == false)

    SharedStorageMigration.markActivated(in: suite)

    #expect(SharedStorageMigration.isCurrentVersionActivated(in: suite))
    #expect(
      Defaults[.sharedStorageActivatedVersion(suite: suite)] == SharedStorageMigration.currentVersion)
  }

  @Test func newerGenerationRecordsCompletionWithoutReimportingLegacy() throws {
    let harness = makeHarness()
    let legacy = ServerConfig(id: UUID(), url: "http://legacy.local", version: .v5)
    let shared = ServerConfig(id: UUID(), url: "http://shared.local", version: .v6)
    Defaults[.servers(suite: harness.legacySuite)] = [legacy]
    Defaults[.servers(suite: harness.sharedSuite)] = [shared]
    Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] = 1

    try harness.migration.migrate(targetVersion: 2)

    let current = Defaults[.servers(suite: harness.sharedSuite)]
    #expect(current.map(\.id) == [shared.id])
    #expect(current[0].url == "http://shared.local")
    #expect(Defaults[.servers(suite: harness.legacySuite)].map(\.id) == [legacy.id])
    #expect(Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] == 2)
    #expect(harness.legacyKeychain.readCallCount == 0)
  }

  @Test func generationBumpMarkerWriteFailureRestoresPreviousVersion() throws {
    let sharedSuite = TestUserDefaults()
    Defaults[.sharedStorageMigrationVersion(suite: sharedSuite)] = 1
    sharedSuite.rejectedWriteKeys = [Defaults.Keys.sharedStorageMigrationVersion(suite: sharedSuite).name]
    let harness = makeHarness(shared: (sharedSuite.domainName, sharedSuite))

    #expect(throws: SharedStorageMigrationError.completionMarkerNotPersisted) {
      try harness.migration.migrate(targetVersion: 2)
    }

    #expect(Defaults[.sharedStorageMigrationVersion(suite: sharedSuite)] == 1)
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
    let harness = makeHarness(shared: (sharedSuite.domainName, sharedSuite))
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

  @Test func malformedSharedResetWriteRejectionFailsClosed() throws {
    let sharedSuite = TestUserDefaults()
    let legacySuite = TestDefaults.makeSuite()
    setRawDefaultsValue(["not-json"], for: Defaults.Keys.servers(suite: sharedSuite))
    sharedSuite.rejectedWriteKeys = [Defaults.Keys.servers(suite: sharedSuite).name]
    setRawDefaultsValue(["not-json"], for: Defaults.Keys.servers(suite: legacySuite))
    let harness = makeHarness(
      legacySuite: legacySuite,
      shared: (sharedSuite.domainName, sharedSuite)
    )

    #expect(throws: SharedStorageMigrationError.sharedConfigurationResetFailed) {
      try harness.migration.migrate()
    }

    #expect(Defaults[.sharedStorageMigrationVersion(suite: sharedSuite)] == 0)
  }

  @Test func sharedConfigurationResetWriteFailureFailsClosed() throws {
    let sharedSuite = TestUserDefaults()
    sharedSuite.rejectedWriteKeys = [Defaults.Keys.servers(suite: sharedSuite).name]
    let harness = makeHarness(shared: (sharedSuite.domainName, sharedSuite))
    let server = ServerConfig(id: UUID(), url: "http://pihole.local", version: .v6)
    Defaults[.servers(suite: harness.legacySuite)] = [server]

    #expect(throws: SharedStorageMigrationError.sharedConfigurationResetFailed) {
      try harness.migration.migrate()
    }

    #expect(Defaults[.sharedStorageMigrationVersion(suite: sharedSuite)] == 0)
    #expect(Defaults[.servers(suite: harness.legacySuite)].map(\.id) == [server.id])
  }

  @Test func sharedTemporaryRecordsWriteFailureStartsFreshAndCompletes() throws {
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
    let harness = makeHarness(shared: (sharedSuite.domainName, sharedSuite))
    Defaults[.servers(suite: harness.legacySuite)] = [server]
    Defaults[.tempUnblocks(for: server.id, suite: harness.legacySuite)] = records

    try harness.migration.migrate()

    #expect(Defaults[.servers(suite: sharedSuite)].isEmpty)
    #expect(
      Defaults[.sharedStorageMigrationVersion(suite: sharedSuite)] == SharedStorageMigration.currentVersion)
  }

  @Test func completionMarkerWriteFailureFailsClosed() throws {
    let sharedSuite = TestUserDefaults()
    sharedSuite.rejectedWriteKeys = [Defaults.Keys.sharedStorageMigrationVersion(suite: sharedSuite).name]
    let harness = makeHarness(shared: (sharedSuite.domainName, sharedSuite))
    let server = ServerConfig(id: UUID(), url: "http://pihole.local", version: .v6)
    Defaults[.servers(suite: harness.legacySuite)] = [server]
    try harness.legacyKeychain.saveCredential("legacy-secret", for: server.id)

    #expect(throws: SharedStorageMigrationError.completionMarkerNotPersisted) {
      try harness.migration.migrate()
    }

    #expect(Defaults[.sharedStorageMigrationVersion(suite: sharedSuite)] == 0)
    #expect(try harness.legacyKeychain.readCredential(for: server.id) == "legacy-secret")
  }

  @Test func emptyLegacyCompletionMarkerWriteFailureFailsClosed() throws {
    let sharedSuite = TestUserDefaults()
    sharedSuite.rejectedWriteKeys = [Defaults.Keys.sharedStorageMigrationVersion(suite: sharedSuite).name]
    let harness = makeHarness(shared: (sharedSuite.domainName, sharedSuite))

    #expect(throws: SharedStorageMigrationError.completionMarkerNotPersisted) {
      try harness.migration.migrate()
    }

    #expect(Defaults[.servers(suite: sharedSuite)].isEmpty)
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
    shared: (name: String, suite: UserDefaults) = TestDefaults.makeNamedSuite()
  ) -> Harness {
    let legacyKeychain = MockKeychainManager()
    let sharedKeychain = MockKeychainManager()
    return Harness(
      legacySuite: legacySuite,
      sharedSuite: shared.suite,
      legacyKeychain: legacyKeychain,
      sharedKeychain: sharedKeychain,
      migration: SharedStorageMigration(
        legacySuite: legacySuite,
        sharedSuite: shared.suite,
        sharedSuiteName: shared.name,
        legacyKeychain: legacyKeychain,
        sharedKeychain: sharedKeychain
      )
    )
  }
}
