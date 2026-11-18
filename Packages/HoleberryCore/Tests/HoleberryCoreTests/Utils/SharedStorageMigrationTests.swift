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

  @Test func sharedFactorySelectsDataProtectionKeychain() throws {
    let bundleURL = try TestBundles.makeAppBundle(identifier: "me.example.host")
    defer { TestBundles.remove(bundleURL) }
    let bundle = try TestBundles.bundle(at: bundleURL)

    let keychain = try KeychainManager.shared(
      accessGroup: "TEAMID.me.example.tests.shared",
      interactive: false,
      startingAt: bundle
    )

    #expect(keychain.service == "me.example.host.shared")
    #expect(keychain.service == (try KeychainManager.sharedService(startingAt: bundle)))
    #expect(keychain.accessGroup == "TEAMID.me.example.tests.shared")
    #expect(keychain.usesDataProtectionKeychain)
    #expect(keychain.isInteractive == false)
  }

  @Test func appAndWidgetDeriveTheSameSharedService() throws {
    let appURL = try TestBundles.makeAppBundle(identifier: "me.example.host")
    defer { TestBundles.remove(appURL) }
    let widgetURL = try TestBundles.makeBundle(
      named: "HostWidgets-\(UUID().uuidString).appex",
      identifier: "me.example.host.widgets",
      containingAppIdentifier: "me.example.host"
    )
    defer { TestBundles.remove(widgetURL) }

    let appService = try KeychainManager.sharedService(startingAt: try TestBundles.bundle(at: appURL))
    let widgetService = try KeychainManager.sharedService(
      startingAt: try TestBundles.bundle(at: widgetURL)
    )

    #expect(appService == "me.example.host.shared")
    #expect(widgetService == appService)
  }

  @Test func sharedFactoryRejectsMissingContainingAppMarker() throws {
    let bundleURL = try TestBundles.makeBundle(
      named: "Markerless-\(UUID().uuidString).app",
      identifier: "me.example.standalone"
    )
    defer { TestBundles.remove(bundleURL) }
    let bundle = try TestBundles.bundle(at: bundleURL)

    #expect(
      throws: BundleMetadataError.missingInfoValue("HoleberryContainingAppIdentifier")
    ) {
      try KeychainManager.shared(
        accessGroup: "TEAMID.me.example.tests.shared",
        interactive: false,
        startingAt: bundle
      )
    }
    #expect(
      throws: BundleMetadataError.missingInfoValue("HoleberryContainingAppIdentifier")
    ) {
      try KeychainManager.sharedService(startingAt: bundle)
    }
  }

  @Test func sharedFactoryRejectsUnexpandedContainingAppMarker() throws {
    let bundleURL = try TestBundles.makeBundle(
      named: "Unexpanded-\(UUID().uuidString).appex",
      identifier: "me.example.host.widgets",
      containingAppIdentifier: "$(HOLEBERRY_APP_BUNDLE_IDENTIFIER)"
    )
    defer { TestBundles.remove(bundleURL) }
    let bundle = try TestBundles.bundle(at: bundleURL)

    #expect(
      throws: BundleMetadataError.invalidInfoValue("HoleberryContainingAppIdentifier")
    ) {
      try KeychainManager.shared(
        accessGroup: "TEAMID.me.example.tests.shared",
        interactive: false,
        startingAt: bundle
      )
    }
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

    #expect(try Defaults.Keys.strictlyDecodedPersistedArray(key, suiteName: name).isEmpty)
  }
}

@Suite("Shared storage readiness")
@MainActor
struct SharedStorageReadinessTests {
  @Test func readyStorageReadsOnePersistentDomainSnapshot() throws {
    let suite = TestUserDefaults()
    Defaults[.sharedStorageMigrationVersion(suite: suite)] = SharedStorageMigration.currentVersion
    Defaults[.servers(suite: suite)] = []

    #expect(try SharedStorageMigration.readiness(in: suite, suiteName: suite.domainName) == .ready)
    #expect(suite.persistentDomainReadCount == 1)
  }

  @Test func registeredCompletionValueWithoutPersistedMarkerIsPending() throws {
    let (name, suite) = TestDefaults.makeNamedSuite()
    let marker = Defaults.Keys.sharedStorageMigrationVersion(suite: suite).name
    suite.register(defaults: [marker: SharedStorageMigration.currentVersion])

    #expect(suite.object(forKey: marker) as? Int == SharedStorageMigration.currentVersion)
    #expect(try SharedStorageMigration.readiness(in: suite, suiteName: name) == .pending)
  }

  @Test func currentMarkerWithoutSavedServerArrayThrows() {
    let (name, suite) = TestDefaults.makeNamedSuite()
    suite.set(
      SharedStorageMigration.currentVersion,
      forKey: Defaults.Keys.sharedStorageMigrationVersion(suite: suite).name
    )

    #expect(throws: SharedStorageReadinessError.missingServerConfiguration) {
      try SharedStorageMigration.readiness(in: suite, suiteName: name)
    }
  }

  @Test func currentMarkerWithMalformedServerArrayThrows() {
    let (name, suite) = TestDefaults.makeNamedSuite()
    suite.set(
      SharedStorageMigration.currentVersion,
      forKey: Defaults.Keys.sharedStorageMigrationVersion(suite: suite).name
    )
    suite.set("not-an-array", forKey: Defaults.Keys.servers(suite: suite).name)

    #expect(throws: SharedStorageReadinessError.malformedServerConfiguration) {
      try SharedStorageMigration.readiness(in: suite, suiteName: name)
    }
  }

  @Test func currentMarkerWithExplicitlySavedEmptyServerArrayIsReady() throws {
    let (name, suite) = TestDefaults.makeNamedSuite()
    Defaults[.servers(suite: suite)] = []
    suite.set(
      SharedStorageMigration.currentVersion,
      forKey: Defaults.Keys.sharedStorageMigrationVersion(suite: suite).name
    )

    #expect(try SharedStorageMigration.readiness(in: suite, suiteName: name) == .ready)
  }

  @Test func newerCompletionVersionThrowsUnsupported() {
    let (name, suite) = TestDefaults.makeNamedSuite()
    let newer = SharedStorageMigration.currentVersion + 1
    suite.set(
      newer, forKey: Defaults.Keys.sharedStorageMigrationVersion(suite: suite).name)

    #expect(throws: SharedStorageReadinessError.unsupportedCompletionVersion(newer)) {
      try SharedStorageMigration.readiness(in: suite, suiteName: name)
    }
  }

  @Test func malformedCompletionVersionThrows() {
    let (name, suite) = TestDefaults.makeNamedSuite()
    suite.set(
      "current", forKey: Defaults.Keys.sharedStorageMigrationVersion(suite: suite).name)

    #expect(throws: SharedStorageReadinessError.malformedCompletionVersion) {
      try SharedStorageMigration.readiness(in: suite, suiteName: name)
    }
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

  @Test func leavesTemporaryUnblockRecordsInAppLocalStorage() throws {
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

    #expect(
      harness.sharedSuite.persistentDomain(forName: harness.sharedSuiteName)?[
        Defaults.Keys.tempUnblocks(for: first.id, suite: harness.sharedSuite).name] == nil)
    #expect(
      harness.sharedSuite.persistentDomain(forName: harness.sharedSuiteName)?[
        Defaults.Keys.tempUnblocks(for: second.id, suite: harness.sharedSuite).name] == nil)
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

  @Test func malformedLegacyServersThrowAndImportAfterRepair() throws {
    let harness = makeHarness()
    let key = Defaults.Keys.servers(suite: harness.legacySuite)
    let malformed: [String] = ["not-json"]
    setRawDefaultsValue(malformed, for: key)

    #expect(throws: SharedStorageMigrationError.malformedLegacyConfiguration) {
      try harness.migration.migrate()
    }

    #expect(Defaults[.servers(suite: harness.sharedSuite)].isEmpty)
    #expect(Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] == 0)
    #expect(rawDefaultsValue(for: key) as? [String] == malformed)
    #expect(harness.legacyKeychain.readCallCount == 0)

    let repaired = ServerConfig(id: UUID(), url: "http://repaired.local", version: .v6)
    Defaults[.servers(suite: harness.legacySuite)] = [repaired]
    try harness.legacyKeychain.saveCredential("repaired-secret", for: repaired.id)

    try harness.migration.migrate()

    #expect(Defaults[.servers(suite: harness.sharedSuite)].map(\.id) == [repaired.id])
    #expect(try harness.sharedKeychain.readCredential(for: repaired.id) == "repaired-secret")
    #expect(
      Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] == SharedStorageMigration.currentVersion)
  }

  @Test func malformedLocalTemporaryRecordsDoNotBlockConfigurationMigration() throws {
    let harness = makeHarness()
    let server = ServerConfig(id: UUID(), url: "http://pihole.local", version: .v6)
    Defaults[.servers(suite: harness.legacySuite)] = [server]
    let key = Defaults.Keys.tempUnblocks(for: server.id, suite: harness.legacySuite)
    let malformed: [String] = ["not-json"]
    setRawDefaultsValue(malformed, for: key)

    try harness.migration.migrate()

    #expect(Defaults[.servers(suite: harness.sharedSuite)].map(\.id) == [server.id])
    #expect(Defaults[.tempUnblocks(for: server.id, suite: harness.sharedSuite)].isEmpty)
    #expect(
      Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] == SharedStorageMigration.currentVersion)
    #expect(rawDefaultsValue(for: key) as? [String] == malformed)
    #expect(Defaults[.servers(suite: harness.legacySuite)].map(\.id) == [server.id])
  }

  @Test func sourceCredentialReadFailureThrowsAndKeepsPartialTarget() throws {
    let harness = makeHarness()
    let server = ServerConfig(id: UUID(), url: "http://pihole.local", version: .v6)
    Defaults[.servers(suite: harness.legacySuite)] = [server]
    try harness.legacyKeychain.saveCredential("legacy-secret", for: server.id)
    harness.legacyKeychain.readErrorStub = SharedStorageTestError()

    #expect(throws: SharedStorageTestError.self) {
      try harness.migration.migrate()
    }

    #expect(Defaults[.servers(suite: harness.sharedSuite)].map(\.id) == [server.id])
    #expect(try harness.sharedKeychain.readCredential(for: server.id) == nil)
    #expect(Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] == 0)
    #expect(Defaults[.servers(suite: harness.legacySuite)].map(\.id) == [server.id])
    #expect(harness.legacyKeychain.storedCredentials[server.id.uuidString] == "legacy-secret")

    harness.legacyKeychain.readErrorStub = nil

    try harness.migration.migrate()

    #expect(try harness.sharedKeychain.readCredential(for: server.id) == "legacy-secret")
    #expect(
      Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] == SharedStorageMigration.currentVersion)
  }

  @Test func midImportCredentialFailureKeepsCopiedConfigurationAndFirstCredential() throws {
    let harness = makeHarness()
    let first = ServerConfig(id: UUID(), url: "http://first.local", version: .v6)
    let second = ServerConfig(id: UUID(), url: "http://second.local", version: .v6)
    Defaults[.servers(suite: harness.legacySuite)] = [first, second]
    try harness.legacyKeychain.saveCredential("first-secret", for: first.id)
    try harness.legacyKeychain.saveCredential("second-secret", for: second.id)
    harness.sharedKeychain.saveErrorsByServerID[second.id] = SharedStorageTestError()

    #expect(throws: SharedStorageTestError.self) {
      try harness.migration.migrate()
    }

    #expect(Defaults[.servers(suite: harness.sharedSuite)].map(\.id) == [first.id, second.id])
    #expect(try harness.sharedKeychain.readCredential(for: first.id) == "first-secret")
    #expect(try harness.sharedKeychain.readCredential(for: second.id) == nil)
    #expect(Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] == 0)
    #expect(Defaults[.servers(suite: harness.legacySuite)].map(\.id) == [first.id, second.id])
    #expect(harness.legacyKeychain.storedCredentials[first.id.uuidString] == "first-secret")
    #expect(harness.legacyKeychain.storedCredentials[second.id.uuidString] == "second-secret")

    harness.sharedKeychain.saveErrorsByServerID.removeAll()

    try harness.migration.migrate()

    #expect(try harness.sharedKeychain.readCredential(for: first.id) == "first-secret")
    #expect(try harness.sharedKeychain.readCredential(for: second.id) == "second-secret")
    #expect(
      Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] == SharedStorageMigration.currentVersion)
  }

  @Test func credentialReadbackMismatchThrowsAndRetries() throws {
    let harness = makeHarness()
    let server = ServerConfig(id: UUID(), url: "http://pihole.local", version: .v6)
    Defaults[.servers(suite: harness.legacySuite)] = [server]
    try harness.legacyKeychain.saveCredential("legacy-secret", for: server.id)
    harness.sharedKeychain.readResultOverride = .success("different-secret")

    #expect(throws: SharedStorageMigrationError.credentialReadbackMismatch(server.id)) {
      try harness.migration.migrate()
    }

    #expect(Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] == 0)
    #expect(Defaults[.servers(suite: harness.sharedSuite)].map(\.id) == [server.id])
    #expect(try harness.legacyKeychain.readCredential(for: server.id) == "legacy-secret")

    try harness.migration.migrate()

    #expect(try harness.sharedKeychain.readCredential(for: server.id) == "legacy-secret")
    #expect(
      Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] == SharedStorageMigration.currentVersion)
  }

  @Test func retryImportsCurrentLegacyEdits() throws {
    let harness = makeHarness()
    let original = ServerConfig(id: UUID(), url: "http://original.local", version: .v6)
    Defaults[.servers(suite: harness.legacySuite)] = [original]
    try harness.legacyKeychain.saveCredential("original-secret", for: original.id)
    harness.sharedKeychain.saveErrorStub = SharedStorageTestError()

    #expect(throws: SharedStorageTestError.self) {
      try harness.migration.migrate()
    }
    #expect(Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] == 0)

    var edited = original
    edited.label = "Renamed"
    edited.url = "http://edited.local"
    let added = ServerConfig(id: UUID(), url: "http://added.local", version: .v5)
    Defaults[.servers(suite: harness.legacySuite)] = [edited, added]
    try harness.legacyKeychain.saveCredential("added-secret", for: added.id)

    harness.sharedKeychain.saveErrorStub = nil

    try harness.migration.migrate()

    let shared = Defaults[.servers(suite: harness.sharedSuite)]
    #expect(shared.count == 2)
    #expect(shared.map(\.id) == [original.id, added.id])
    #expect(shared.first?.label == "Renamed")
    #expect(shared.first?.url == "http://edited.local")
    #expect(shared.dropFirst().first?.version == .v5)
    #expect(try harness.sharedKeychain.readCredential(for: original.id) == "original-secret")
    #expect(try harness.sharedKeychain.readCredential(for: added.id) == "added-secret")
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
    #expect(Defaults[.tempUnblocks(for: removed.id, suite: harness.sharedSuite)] == [staleRecord])
    #expect(try harness.sharedKeychain.readCredential(for: removed.id) == nil)
    #expect(
      Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] == SharedStorageMigration.currentVersion)
  }

  @Test func malformedPriorSharedServersBlockMigrationUntilRepaired() throws {
    let harness = makeHarness()
    let kept = ServerConfig(id: UUID(), url: "http://kept.local", version: .v6)
    let removed = ServerConfig(id: UUID(), url: "http://removed.local", version: .v6)
    let key = Defaults.Keys.servers(suite: harness.sharedSuite)
    let encoded = try #require([ServerConfig].bridge.serialize([removed]))
    let malformed = encoded + ["not-json"]
    Defaults[.servers(suite: harness.legacySuite)] = [kept]
    setRawDefaultsValue(malformed, for: key)
    try harness.sharedKeychain.saveCredential("stale-secret", for: removed.id)

    #expect(throws: SharedStorageReadinessError.malformedServerConfiguration) {
      try harness.migration.migrate()
    }

    #expect(rawDefaultsValue(for: key) as? [String] == malformed)
    #expect(Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] == 0)
    #expect(harness.sharedKeychain.deleteCallCount == 0)
    #expect(harness.legacyKeychain.readCallCount == 0)

    Defaults[key] = [removed]
    try harness.migration.migrate()

    #expect(Defaults[key].map(\.id) == [kept.id])
    #expect(try harness.sharedKeychain.readCredential(for: removed.id) == nil)
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

  @Test func activationRecordsCurrentVersionInLegacySuite() throws {
    let (name, suite) = TestDefaults.makeNamedSuite()
    let key = Defaults.Keys.sharedStorageActivatedVersion(suite: suite)

    #expect(Defaults[key] == 0)

    try SharedStorageMigration.markActivated(in: suite, suiteName: name)

    #expect(Defaults[key] == SharedStorageMigration.currentVersion)
    #expect(suite.persistentDomain(forName: name)?[key.name] as? Int == SharedStorageMigration.currentVersion)
  }

  @Test func activationRecordWriteFailureThrows() {
    let suite = TestUserDefaults()
    suite.rejectedWriteKeys = [Defaults.Keys.sharedStorageActivatedVersion(suite: suite).name]

    #expect(throws: SharedStorageMigrationError.activationRecordNotPersisted) {
      try SharedStorageMigration.markActivated(in: suite, suiteName: suite.domainName)
    }
  }

  @Test func activationReaderIgnoresSearchDomainValue() throws {
    let suite = TestUserDefaults()
    let key = Defaults.Keys.sharedStorageActivatedVersion(suite: suite)
    suite.register(defaults: [key.name: SharedStorageMigration.currentVersion])

    #expect(try SharedStorageMigration.activatedVersion(in: suite, suiteName: suite.domainName) == 0)
  }

  @Test func negativePersistedActivationVersionIsRejected() {
    let (name, suite) = TestDefaults.makeNamedSuite()
    suite.set(-1, forKey: Defaults.Keys.sharedStorageActivatedVersion(suite: suite).name)

    #expect(throws: SharedStorageMigrationError.activationRecordNotPersisted) {
      try SharedStorageMigration.activatedVersion(in: suite, suiteName: name)
    }
  }

  @Test func malformedPersistedActivationVersionIsRejected() {
    let (name, suite) = TestDefaults.makeNamedSuite()
    suite.set("current", forKey: Defaults.Keys.sharedStorageActivatedVersion(suite: suite).name)

    #expect(throws: SharedStorageMigrationError.activationRecordNotPersisted) {
      try SharedStorageMigration.activatedVersion(in: suite, suiteName: name)
    }
  }

  @Test func activationReaderReturnsPersistedVersion() throws {
    let (name, suite) = TestDefaults.makeNamedSuite()
    try SharedStorageMigration.markActivated(in: suite, suiteName: name)

    #expect(
      try SharedStorageMigration.activatedVersion(in: suite, suiteName: name)
        == SharedStorageMigration.currentVersion
    )
  }

  @Test func registeredCompletionMarkerDoesNotSkipFirstImport() throws {
    let sharedSuite = TestUserDefaults()
    let marker = Defaults.Keys.sharedStorageMigrationVersion(suite: sharedSuite).name
    sharedSuite.register(defaults: [marker: SharedStorageMigration.currentVersion])
    let harness = makeHarness(shared: (sharedSuite.domainName, sharedSuite))
    let server = ServerConfig(id: UUID(), url: "http://pihole.local", version: .v6)
    Defaults[.servers(suite: harness.legacySuite)] = [server]

    try harness.migration.migrate()

    #expect(Defaults[.servers(suite: sharedSuite)].map(\.id) == [server.id])
    #expect(
      sharedSuite.persistentDomain(forName: sharedSuite.domainName)?[marker] as? Int
        == SharedStorageMigration.currentVersion
    )
  }

  @Test func negativeCompletionMarkerRejectsMigrationBeforeAnyWrites() {
    let harness = makeHarness()
    let markerKey = Defaults.Keys.sharedStorageMigrationVersion(suite: harness.sharedSuite)
    let server = ServerConfig(id: UUID(), url: "http://pihole.local", version: .v6)
    Defaults[markerKey] = -1
    Defaults[.servers(suite: harness.legacySuite)] = [server]

    #expect(throws: SharedStorageReadinessError.unsupportedCompletionVersion(-1)) {
      try harness.migration.migrate()
    }

    #expect(Defaults[markerKey] == -1)
    #expect(Defaults[.servers(suite: harness.sharedSuite)].isEmpty)
    #expect(harness.legacyKeychain.readCallCount == 0)
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

  @Test func emptyLocalTemporaryRecordsDoNotBlockMigration() throws {
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
    #expect(Defaults[.tempUnblocks(for: server.id, suite: sharedSuite)].isEmpty)
    #expect(try harness.sharedKeychain.readCredential(for: server.id) == "legacy-secret")
    #expect(
      Defaults[.sharedStorageMigrationVersion(suite: sharedSuite)] == SharedStorageMigration.currentVersion)
  }

  @Test func rejectedSharedConfigurationWritePropagatesAndPreservesSource() throws {
    let sharedSuite = TestUserDefaults()
    sharedSuite.rejectedWriteKeys = [Defaults.Keys.servers(suite: sharedSuite).name]
    let harness = makeHarness(shared: (sharedSuite.domainName, sharedSuite))
    let server = ServerConfig(id: UUID(), url: "http://pihole.local", version: .v6)
    Defaults[.servers(suite: harness.legacySuite)] = [server]
    try harness.legacyKeychain.saveCredential("legacy-secret", for: server.id)

    #expect(throws: SharedStorageMigrationError.configurationReadbackMismatch) {
      try harness.migration.migrate()
    }

    #expect(Defaults[.sharedStorageMigrationVersion(suite: sharedSuite)] == 0)
    #expect(Defaults[.servers(suite: harness.legacySuite)].map(\.id) == [server.id])
    #expect(try harness.legacyKeychain.readCredential(for: server.id) == "legacy-secret")
  }

  @Test func migrationNeverWritesSharedTemporaryUnblockRecords() throws {
    let sharedSuite = TestUserDefaults()
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

    try harness.migration.migrate()

    let sharedKey = Defaults.Keys.tempUnblocks(for: server.id, suite: sharedSuite).name
    // The servers key proves the recording spy observes this migration's writes,
    // so the absent temporary-unblock key is a real absence, not an empty log.
    #expect(sharedSuite.attemptedSetKeys.contains(Defaults.Keys.servers(suite: sharedSuite).name))
    #expect(sharedSuite.attemptedSetKeys.contains(sharedKey) == false)
    #expect(sharedSuite.attemptedRemoveKeys.contains(sharedKey) == false)
    #expect(sharedSuite.persistentDomain(forName: sharedSuite.domainName)?[sharedKey] == nil)
    #expect(Defaults[.servers(suite: sharedSuite)].map(\.id) == [server.id])
    #expect(Defaults[.tempUnblocks(for: server.id, suite: harness.legacySuite)] == records)
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
    let sharedSuiteName: String
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
      sharedSuiteName: shared.name,
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
