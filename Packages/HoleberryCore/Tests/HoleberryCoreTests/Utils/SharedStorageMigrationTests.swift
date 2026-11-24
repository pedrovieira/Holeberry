import Defaults
import Foundation
import Testing

@testable import HoleberryCore

private struct SharedStorageTestError: Error, Equatable {}

@Suite("KeychainManager options")
@MainActor
struct KeychainManagerOptionsTests {
  @Test func deletingMissingCredentialIsIdempotent() throws {
    let keychain = KeychainManager(service: "me.holeberry.tests.\(UUID().uuidString)", interactive: false)
    let id = UUID()

    try keychain.deleteCredential(for: id)
    try keychain.deleteCredential(for: id)
  }

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
  @Test func registeredFallbackIsNotPersistedServers() throws {
    let (name, suite) = TestDefaults.makeNamedSuite()
    let key = Defaults.Keys.servers(suite: suite)

    #expect(suite.object(forKey: key.name) != nil)
    #expect(suite.persistentDomain(forName: name)?[key.name] == nil)
    #expect(try PersistedStartupValue.servers(in: suite, suiteName: name) == nil)
  }

  @Test func explicitlySavedEmptyArrayIsPersisted() throws {
    let (name, suite) = TestDefaults.makeNamedSuite()
    let key = Defaults.Keys.servers(suite: suite)

    Defaults[key] = []

    #expect(try PersistedStartupValue.servers(in: suite, suiteName: name)?.isEmpty == true)
  }
}

@Suite("SharedStorageValidation")
@MainActor
struct SharedStorageReadinessTests {
  @Test func completedStoreWithDuplicateServerIDsRequiresRecovery() {
    let (name, suite) = TestDefaults.makeNamedSuite()
    let server = ServerConfig(id: UUID(), url: "http://pihole.local", version: .v6)
    Defaults[.servers(suite: suite)] = [server, server]
    Defaults[.sharedStorageMigrationVersion(suite: suite)] = SharedStorageValidation.currentVersion

    #expect(throws: SharedStorageReadinessError.malformedServerConfiguration) {
      try SharedStorageValidation.readiness(in: suite, suiteName: name)
    }
  }

  @Test func registeredCompletionValueWithoutPersistedMarkerIsPending() throws {
    let (name, suite) = TestDefaults.makeNamedSuite()
    let marker = Defaults.Keys.sharedStorageMigrationVersion(suite: suite).name
    suite.register(defaults: [marker: SharedStorageValidation.currentVersion])

    #expect(suite.object(forKey: marker) as? Int == SharedStorageValidation.currentVersion)
    #expect(try SharedStorageValidation.readiness(in: suite, suiteName: name) == .pending)
  }

  @Test func currentMarkerWithoutSavedServerArrayThrows() {
    let (name, suite) = TestDefaults.makeNamedSuite()
    suite.set(
      SharedStorageValidation.currentVersion,
      forKey: Defaults.Keys.sharedStorageMigrationVersion(suite: suite).name
    )

    #expect(throws: SharedStorageReadinessError.missingServerConfiguration) {
      try SharedStorageValidation.readiness(in: suite, suiteName: name)
    }
  }

  @Test func currentMarkerWithMalformedServerArrayThrows() {
    let (name, suite) = TestDefaults.makeNamedSuite()
    suite.set(
      SharedStorageValidation.currentVersion,
      forKey: Defaults.Keys.sharedStorageMigrationVersion(suite: suite).name
    )
    suite.set("not-an-array", forKey: Defaults.Keys.servers(suite: suite).name)

    #expect(throws: SharedStorageReadinessError.malformedServerConfiguration) {
      try SharedStorageValidation.readiness(in: suite, suiteName: name)
    }
  }

  @Test func currentMarkerWithExplicitlySavedEmptyServerArrayIsReady() throws {
    let (name, suite) = TestDefaults.makeNamedSuite()
    Defaults[.servers(suite: suite)] = []
    suite.set(
      SharedStorageValidation.currentVersion,
      forKey: Defaults.Keys.sharedStorageMigrationVersion(suite: suite).name
    )

    #expect(try SharedStorageValidation.readiness(in: suite, suiteName: name) == .ready)
  }

  @Test func newerCompletionVersionThrowsUnsupported() {
    let (name, suite) = TestDefaults.makeNamedSuite()
    let newer = SharedStorageValidation.currentVersion + 1
    suite.set(
      newer, forKey: Defaults.Keys.sharedStorageMigrationVersion(suite: suite).name)

    #expect(throws: SharedStorageReadinessError.unsupportedCompletionVersion(newer)) {
      try SharedStorageValidation.readiness(in: suite, suiteName: name)
    }
  }

  @Test func malformedCompletionVersionThrows() {
    let (name, suite) = TestDefaults.makeNamedSuite()
    suite.set(
      "current", forKey: Defaults.Keys.sharedStorageMigrationVersion(suite: suite).name)

    #expect(throws: SharedStorageReadinessError.malformedCompletionVersion) {
      try SharedStorageValidation.readiness(in: suite, suiteName: name)
    }
  }
}

@Suite("Legacy copy engine")
@MainActor
struct SharedStorageMigrationTests {
  @Test func launchArgumentCannotReplacePersistedLegacyServers() throws {
    let legacy = TestDefaults.makeNamedSuite()
    let harness = makeHarness(legacy: legacy)
    let server = ServerConfig(id: UUID(), url: "http://saved.local", version: .v6)
    let key = Defaults.Keys.servers(suite: legacy.suite)
    Defaults[key] = [server]
    let arguments = legacy.suite.volatileDomain(forName: UserDefaults.argumentDomain)
    defer { legacy.suite.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain) }
    legacy.suite.setVolatileDomain([key.name: [String]()], forName: UserDefaults.argumentDomain)
    #expect(legacy.suite.object(forKey: key.name) as? [String] == [])

    try harness.copy.migrate()

    // Migration must read the persistent domain, not the argument domain.
    #expect(
      try PersistedStartupValue.servers(in: harness.sharedSuite, suiteName: harness.sharedSuiteName)?
        .map(\.id) == [server.id])

    legacy.suite.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    let storage = ConcreteConnectionStore(suite: harness.sharedSuite, keychain: harness.sharedKeychain)
    #expect(storage.loadServers().map(\.id) == [server.id])
    let added = ServerConfig(id: UUID(), url: "http://added.local", version: .v6)
    storage.saveServers(storage.loadServers() + [added])
    let saved = try PersistedStartupValue.servers(in: harness.sharedSuite, suiteName: harness.sharedSuiteName)
    #expect(saved?.map(\.id) == [server.id, added.id])
    #expect(
      Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] == SharedStorageValidation.currentVersion)
    let persisted = try PersistedStartupValue.servers(in: legacy.suite, suiteName: legacy.name)
    #expect(persisted?.map(\.id) == [server.id])
  }

  @Test func duplicateLegacyServerIDsRejectImportWithoutChangingEitherStore() throws {
    let harness = makeHarness()
    let first = ServerConfig(id: UUID(), url: "http://first.local", version: .v6)
    let duplicate = ServerConfig(id: first.id, url: "http://second.local", version: .v5)
    Defaults[.servers(suite: harness.legacySuite)] = [first, duplicate]
    try harness.legacyKeychain.saveCredential("legacy-secret", for: first.id)

    #expect(throws: SharedStorageMigrationError.malformedLegacyConfiguration) {
      try harness.copy.migrate()
    }

    #expect(Defaults[.servers(suite: harness.legacySuite)].map(\.url) == ["http://first.local", "http://second.local"])
    #expect(Defaults[.servers(suite: harness.sharedSuite)].isEmpty)
    #expect(Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] == 0)
    #expect(try harness.legacyKeychain.readCredential(for: first.id) == "legacy-secret")
    #expect(try harness.sharedKeychain.readCredential(for: first.id) == nil)
  }

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

    try harness.copy.migrate()

    let shared = Defaults[.servers(suite: harness.sharedSuite)]
    try #require(shared.count == 2)
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
      Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] == SharedStorageValidation.currentVersion)
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

    try harness.copy.migrate()

    #expect(
      harness.sharedSuite.persistentDomain(forName: harness.sharedSuiteName)?[
        Defaults.Keys.tempUnblocks(for: first.id, suite: harness.sharedSuite).name] == nil)
    #expect(
      harness.sharedSuite.persistentDomain(forName: harness.sharedSuiteName)?[
        Defaults.Keys.tempUnblocks(for: second.id, suite: harness.sharedSuite).name] == nil)
    #expect(Defaults[.tempUnblocks(for: first.id, suite: harness.legacySuite)] == firstRecords)
    #expect(Defaults[.tempUnblocks(for: second.id, suite: harness.legacySuite)] == secondRecords)
  }

  @Test func copiesCredential() throws {
    let harness = makeHarness()
    let server = ServerConfig(id: UUID(), url: "http://pihole.local", version: .v6)
    Defaults[.servers(suite: harness.legacySuite)] = [server]
    try harness.legacyKeychain.saveCredential("legacy-secret", for: server.id)

    try harness.copy.migrate()

    #expect(try harness.sharedKeychain.readCredential(for: server.id) == "legacy-secret")
    #expect(try harness.legacyKeychain.readCredential(for: server.id) == "legacy-secret")
    #expect(
      Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] == SharedStorageValidation.currentVersion)
  }

  @Test func passwordlessServerRemovesPriorPartialSharedCredential() throws {
    let harness = makeHarness()
    let server = ServerConfig(id: UUID(), url: "http://pihole.local", version: .v6)
    Defaults[.servers(suite: harness.legacySuite)] = [server]
    try harness.sharedKeychain.saveCredential("partial-secret", for: server.id)

    try harness.copy.migrate()

    #expect(try harness.sharedKeychain.readCredential(for: server.id) == nil)
    #expect(try harness.legacyKeychain.readCredential(for: server.id) == nil)
    #expect(
      Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] == SharedStorageValidation.currentVersion)
  }

  @Test(arguments: [false, true])
  func cleanupDeletesUnreadableSharedCredential(passwordless: Bool) throws {
    let harness = makeHarness()
    let server = ServerConfig(id: UUID(), url: "http://pihole.local", version: .v6)
    Defaults[.servers(suite: harness.legacySuite)] = passwordless ? [server] : []
    Defaults[.servers(suite: harness.sharedSuite)] = [server]
    try harness.sharedKeychain.saveCredential("stale-secret", for: server.id)
    harness.sharedKeychain.readErrorStub = URLError(.cannotDecodeContentData)

    try harness.copy.migrate()

    #expect(harness.sharedKeychain.storedCredentials[server.id.uuidString] == nil)
    #expect(harness.sharedKeychain.readCallCount == 0)
    #expect(harness.sharedKeychain.deleteCallCount == 1)
    #expect(Defaults[.servers(suite: harness.sharedSuite)].map(\.id) == (passwordless ? [server.id] : []))
    #expect(
      Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] == SharedStorageValidation.currentVersion)
  }

  @Test(arguments: [false, true])
  func cleanupDeletionFailureKeepsMigrationPending(passwordless: Bool) throws {
    let harness = makeHarness()
    let server = ServerConfig(id: UUID(), url: "http://pihole.local", version: .v6)
    Defaults[.servers(suite: harness.legacySuite)] = passwordless ? [server] : []
    Defaults[.servers(suite: harness.sharedSuite)] = [server]
    try harness.sharedKeychain.saveCredential("stale-secret", for: server.id)
    harness.sharedKeychain.readErrorStub = URLError(.cannotDecodeContentData)
    harness.sharedKeychain.deleteErrorStub = SharedStorageTestError()

    #expect(throws: SharedStorageTestError.self) {
      try harness.copy.migrate()
    }

    #expect(harness.sharedKeychain.storedCredentials[server.id.uuidString] == "stale-secret")
    #expect(harness.sharedKeychain.readCallCount == 0)
    #expect(harness.sharedKeychain.deleteCallCount == 1)
    #expect(Defaults[.servers(suite: harness.sharedSuite)].map(\.id) == [server.id])
    #expect(Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] == 0)
  }

  @Test func emptyConfigurationCompletesAndNeverResurrectsLaterLegacyServers() throws {
    let harness = makeHarness()

    try harness.copy.migrate()

    #expect(Defaults[.servers(suite: harness.sharedSuite)].isEmpty)
    #expect(
      Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] == SharedStorageValidation.currentVersion)
    #expect(harness.legacyKeychain.readCallCount == 0)
    #expect(harness.sharedKeychain.storedCredentials.isEmpty)

    let late = ServerConfig(id: UUID(), url: "http://late.local", version: .v6)
    Defaults[.servers(suite: harness.legacySuite)] = [late]
    try harness.legacyKeychain.saveCredential("late-secret", for: late.id)

    try harness.copy.migrate()

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
      try harness.copy.migrate()
    }

    #expect(Defaults[.servers(suite: harness.sharedSuite)].isEmpty)
    #expect(Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] == 0)
    #expect(rawDefaultsValue(for: key) as? [String] == malformed)
    #expect(harness.legacyKeychain.readCallCount == 0)

    let repaired = ServerConfig(id: UUID(), url: "http://repaired.local", version: .v6)
    Defaults[.servers(suite: harness.legacySuite)] = [repaired]
    try harness.legacyKeychain.saveCredential("repaired-secret", for: repaired.id)

    try harness.copy.migrate()

    #expect(Defaults[.servers(suite: harness.sharedSuite)].map(\.id) == [repaired.id])
    #expect(try harness.sharedKeychain.readCredential(for: repaired.id) == "repaired-secret")
    #expect(
      Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] == SharedStorageValidation.currentVersion)
  }

  @Test func malformedLocalTemporaryRecordsDoNotBlockConfigurationMigration() throws {
    let harness = makeHarness()
    let server = ServerConfig(id: UUID(), url: "http://pihole.local", version: .v6)
    Defaults[.servers(suite: harness.legacySuite)] = [server]
    let key = Defaults.Keys.tempUnblocks(for: server.id, suite: harness.legacySuite)
    let malformed: [String] = ["not-json"]
    setRawDefaultsValue(malformed, for: key)

    try harness.copy.migrate()

    #expect(Defaults[.servers(suite: harness.sharedSuite)].map(\.id) == [server.id])
    #expect(Defaults[.tempUnblocks(for: server.id, suite: harness.sharedSuite)].isEmpty)
    #expect(
      Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] == SharedStorageValidation.currentVersion)
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
      try harness.copy.migrate()
    }

    #expect(Defaults[.servers(suite: harness.sharedSuite)].map(\.id) == [server.id])
    #expect(try harness.sharedKeychain.readCredential(for: server.id) == nil)
    #expect(Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] == 0)
    #expect(Defaults[.servers(suite: harness.legacySuite)].map(\.id) == [server.id])
    #expect(harness.legacyKeychain.storedCredentials[server.id.uuidString] == "legacy-secret")

    harness.legacyKeychain.readErrorStub = nil

    try harness.copy.migrate()

    #expect(try harness.sharedKeychain.readCredential(for: server.id) == "legacy-secret")
    #expect(
      Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] == SharedStorageValidation.currentVersion)
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
      try harness.copy.migrate()
    }

    #expect(Defaults[.servers(suite: harness.sharedSuite)].map(\.id) == [first.id, second.id])
    #expect(try harness.sharedKeychain.readCredential(for: first.id) == "first-secret")
    #expect(try harness.sharedKeychain.readCredential(for: second.id) == nil)
    #expect(Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] == 0)
    #expect(Defaults[.servers(suite: harness.legacySuite)].map(\.id) == [first.id, second.id])
    #expect(harness.legacyKeychain.storedCredentials[first.id.uuidString] == "first-secret")
    #expect(harness.legacyKeychain.storedCredentials[second.id.uuidString] == "second-secret")

    harness.sharedKeychain.saveErrorsByServerID.removeAll()

    try harness.copy.migrate()

    #expect(try harness.sharedKeychain.readCredential(for: first.id) == "first-secret")
    #expect(try harness.sharedKeychain.readCredential(for: second.id) == "second-secret")
    #expect(
      Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] == SharedStorageValidation.currentVersion)
  }

  @Test func retryImportsCurrentLegacyEdits() throws {
    let harness = makeHarness()
    let original = ServerConfig(id: UUID(), url: "http://original.local", version: .v6)
    Defaults[.servers(suite: harness.legacySuite)] = [original]
    try harness.legacyKeychain.saveCredential("original-secret", for: original.id)
    harness.sharedKeychain.saveErrorStub = SharedStorageTestError()

    #expect(throws: SharedStorageTestError.self) {
      try harness.copy.migrate()
    }
    #expect(Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] == 0)

    var edited = original
    edited.label = "Renamed"
    edited.url = "http://edited.local"
    let added = ServerConfig(id: UUID(), url: "http://added.local", version: .v5)
    Defaults[.servers(suite: harness.legacySuite)] = [edited, added]
    try harness.legacyKeychain.saveCredential("added-secret", for: added.id)

    harness.sharedKeychain.saveErrorStub = nil

    try harness.copy.migrate()

    let shared = Defaults[.servers(suite: harness.sharedSuite)]
    #expect(shared.count == 2)
    #expect(shared.map(\.id) == [original.id, added.id])
    #expect(shared.first?.label == "Renamed")
    #expect(shared.first?.url == "http://edited.local")
    #expect(shared.dropFirst().first?.version == .v5)
    #expect(try harness.sharedKeychain.readCredential(for: original.id) == "original-secret")
    #expect(try harness.sharedKeychain.readCredential(for: added.id) == "added-secret")
    #expect(
      Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] == SharedStorageValidation.currentVersion)
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

    try harness.copy.migrate()

    let shared = Defaults[.servers(suite: harness.sharedSuite)]
    try #require(shared.count == 1)
    #expect(shared[0].id == kept.id)
    #expect(shared[0].url == "http://kept.local")
    #expect(Defaults[.tempUnblocks(for: removed.id, suite: harness.sharedSuite)] == [staleRecord])
    #expect(try harness.sharedKeychain.readCredential(for: removed.id) == nil)
    #expect(
      Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] == SharedStorageValidation.currentVersion)
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
      try harness.copy.migrate()
    }

    #expect(rawDefaultsValue(for: key) as? [String] == malformed)
    #expect(Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] == 0)
    #expect(harness.sharedKeychain.deleteCallCount == 0)
    #expect(harness.legacyKeychain.readCallCount == 0)

    Defaults[key] = [removed]
    try harness.copy.migrate()

    #expect(Defaults[key].map(\.id) == [kept.id])
    #expect(try harness.sharedKeychain.readCredential(for: removed.id) == nil)
  }

  @Test func completedMigrationDoesNotConsultLegacy() throws {
    let harness = makeHarness()
    let server = ServerConfig(id: UUID(), url: "http://pihole.local", version: .v6)
    Defaults[.servers(suite: harness.legacySuite)] = [server]
    try harness.legacyKeychain.saveCredential("legacy-secret", for: server.id)

    try harness.copy.migrate()
    let legacyReadsAfterMigration = harness.legacyKeychain.readCallCount
    harness.legacyKeychain.readErrorStub = SharedStorageTestError()

    try harness.copy.migrate()

    #expect(harness.legacyKeychain.readCallCount == legacyReadsAfterMigration)
    #expect(Defaults[.servers(suite: harness.sharedSuite)].count == 1)
    #expect(
      Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] == SharedStorageValidation.currentVersion)
  }

  @Test func completedMigrationKeepsExistingSharedConfiguration() throws {
    let harness = makeHarness()
    let legacy = ServerConfig(id: UUID(), url: "http://legacy.local", version: .v5)
    let shared = ServerConfig(id: UUID(), url: "http://shared.local", version: .v6)
    Defaults[.servers(suite: harness.legacySuite)] = [legacy]
    Defaults[.servers(suite: harness.sharedSuite)] = [shared]
    Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] = SharedStorageValidation.currentVersion

    try harness.copy.migrate()

    let current = Defaults[.servers(suite: harness.sharedSuite)]
    try #require(current.count == 1)
    #expect(current[0].id == shared.id)
    #expect(current[0].url == "http://shared.local")
    #expect(current[0].version == .v6)
    #expect(Defaults[.servers(suite: harness.legacySuite)].map(\.id) == [legacy.id])
    #expect(harness.legacyKeychain.readCallCount == 0)
  }

  @Test func newerCompletionVersionThrowsWithoutChangingEitherStore() throws {
    let legacy = TestDefaults.makeNamedSuite()
    let shared = TestDefaults.makeNamedSuite()
    let harness = makeHarness(legacy: legacy, shared: shared)
    let legacyServer = ServerConfig(id: UUID(), url: "http://legacy.local", version: .v5)
    let sharedServer = ServerConfig(id: UUID(), url: "http://shared.local", version: .v6)
    let newer = SharedStorageValidation.currentVersion + 1
    Defaults[.servers(suite: legacy.suite)] = [legacyServer]
    Defaults[.servers(suite: shared.suite)] = [sharedServer]
    Defaults[.sharedStorageMigrationVersion(suite: shared.suite)] = newer
    try harness.legacyKeychain.saveCredential("legacy-secret", for: legacyServer.id)
    try harness.sharedKeychain.saveCredential("shared-secret", for: sharedServer.id)
    let legacyDefaultsBefore = legacy.suite.persistentDomain(forName: legacy.name) ?? [:]
    let sharedDefaultsBefore = shared.suite.persistentDomain(forName: shared.name) ?? [:]

    #expect(throws: SharedStorageReadinessError.unsupportedCompletionVersion(newer)) {
      try harness.copy.migrate()
    }

    #expect(
      NSDictionary(dictionary: legacyDefaultsBefore).isEqual(
        to:
          legacy.suite.persistentDomain(forName: legacy.name) ?? [:]))
    #expect(
      NSDictionary(dictionary: sharedDefaultsBefore).isEqual(
        to:
          shared.suite.persistentDomain(forName: shared.name) ?? [:]))
    #expect(harness.legacyKeychain.storedCredentials == [legacyServer.id.uuidString: "legacy-secret"])
    #expect(harness.sharedKeychain.storedCredentials == [sharedServer.id.uuidString: "shared-secret"])
    #expect(harness.legacyKeychain.saveCallCount == 1)
    #expect(harness.sharedKeychain.saveCallCount == 1)
    #expect(harness.legacyKeychain.readCallCount == 0)
    #expect(harness.sharedKeychain.readCallCount == 0)
    #expect(harness.legacyKeychain.deleteCallCount == 0)
    #expect(harness.sharedKeychain.deleteCallCount == 0)
  }

  @Test func activationRecordsCurrentVersionInLegacySuite() throws {
    let (name, suite) = TestDefaults.makeNamedSuite()
    let key = Defaults.Keys.sharedStorageActivatedVersion(suite: suite)

    #expect(Defaults[key] == 0)

    StorageLegacyStore.markActivated(in: suite)

    #expect(Defaults[key] == SharedStorageValidation.currentVersion)
    #expect(suite.persistentDomain(forName: name)?[key.name] as? Int == SharedStorageValidation.currentVersion)
  }

  @Test func activationReaderIgnoresSearchDomainValue() throws {
    let (name, suite) = TestDefaults.makeNamedSuite()
    let key = Defaults.Keys.sharedStorageActivatedVersion(suite: suite)
    suite.register(defaults: [key.name: SharedStorageValidation.currentVersion])

    #expect(try StorageLegacyStore.activatedVersion(in: suite, suiteName: name) == 0)
  }

  @Test func negativePersistedActivationVersionIsRejected() {
    let (name, suite) = TestDefaults.makeNamedSuite()
    suite.set(-1, forKey: Defaults.Keys.sharedStorageActivatedVersion(suite: suite).name)

    #expect(throws: SharedStorageMigrationError.malformedActivationRecord) {
      try StorageLegacyStore.activatedVersion(in: suite, suiteName: name)
    }
  }

  @Test func malformedPersistedActivationVersionIsRejected() {
    let (name, suite) = TestDefaults.makeNamedSuite()
    suite.set("current", forKey: Defaults.Keys.sharedStorageActivatedVersion(suite: suite).name)

    #expect(throws: SharedStorageMigrationError.malformedActivationRecord) {
      try StorageLegacyStore.activatedVersion(in: suite, suiteName: name)
    }
  }

  @Test func activationReaderReturnsPersistedVersion() throws {
    let (name, suite) = TestDefaults.makeNamedSuite()
    StorageLegacyStore.markActivated(in: suite)

    #expect(
      try StorageLegacyStore.activatedVersion(in: suite, suiteName: name)
        == SharedStorageValidation.currentVersion
    )
  }

  @Test func registeredCompletionMarkerDoesNotSkipFirstImport() throws {
    let shared = TestDefaults.makeNamedSuite()
    let marker = Defaults.Keys.sharedStorageMigrationVersion(suite: shared.suite).name
    shared.suite.register(defaults: [marker: SharedStorageValidation.currentVersion])
    let harness = makeHarness(shared: shared)
    let server = ServerConfig(id: UUID(), url: "http://pihole.local", version: .v6)
    Defaults[.servers(suite: harness.legacySuite)] = [server]

    try harness.copy.migrate()

    #expect(Defaults[.servers(suite: shared.suite)].map(\.id) == [server.id])
    #expect(
      shared.suite.persistentDomain(forName: shared.name)?[marker] as? Int
        == SharedStorageValidation.currentVersion
    )
  }

  @Test func negativeCompletionMarkerRejectsMigrationBeforeAnyWrites() {
    let harness = makeHarness()
    let markerKey = Defaults.Keys.sharedStorageMigrationVersion(suite: harness.sharedSuite)
    let server = ServerConfig(id: UUID(), url: "http://pihole.local", version: .v6)
    Defaults[markerKey] = -1
    Defaults[.servers(suite: harness.legacySuite)] = [server]

    #expect(throws: SharedStorageReadinessError.unsupportedCompletionVersion(-1)) {
      try harness.copy.migrate()
    }

    #expect(Defaults[markerKey] == -1)
    #expect(Defaults[.servers(suite: harness.sharedSuite)].isEmpty)
    #expect(harness.legacyKeychain.readCallCount == 0)
  }

  @Test func malformedCompletionMarkerRejectsMigrationBeforeAnyWrites() {
    for value: Any in ["current", true, 1.5] {
      let shared = TestDefaults.makeNamedSuite()
      let markerKey = Defaults.Keys.sharedStorageMigrationVersion(suite: shared.suite)
      setRawDefaultsValue(value, for: markerKey)
      let harness = makeHarness(shared: shared)

      #expect(throws: SharedStorageReadinessError.malformedCompletionVersion) {
        try harness.copy.migrate()
      }

      #expect(Defaults[.servers(suite: shared.suite)].isEmpty)
      #expect(harness.legacyKeychain.readCallCount == 0)
    }
  }

  @Test func explicitEmptyServerArrayMigratesNormally() throws {
    let harness = makeHarness()
    Defaults[.servers(suite: harness.legacySuite)] = []

    try harness.copy.migrate()

    #expect(Defaults[.servers(suite: harness.sharedSuite)].isEmpty)
    #expect(
      Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] == SharedStorageValidation.currentVersion)
  }

  @Test func emptyLocalTemporaryRecordsDoNotBlockMigration() throws {
    let harness = makeHarness()
    let server = ServerConfig(id: UUID(), url: "http://pihole.local", version: .v6)
    Defaults[.servers(suite: harness.legacySuite)] = [server]
    Defaults[.tempUnblocks(for: server.id, suite: harness.legacySuite)] = []

    try harness.copy.migrate()

    #expect(Defaults[.tempUnblocks(for: server.id, suite: harness.sharedSuite)].isEmpty)
    #expect(
      Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] == SharedStorageValidation.currentVersion)
  }

  @Test func completedMigrationCopiesConfigurationAndCredentialsWithoutTemporaryRecords() throws {
    let shared = TestDefaults.makeNamedSuite()
    let harness = makeHarness(shared: shared)
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

    try harness.copy.migrate()

    #expect(Defaults[.servers(suite: shared.suite)].map(\.id) == [server.id])
    #expect(Defaults[.tempUnblocks(for: server.id, suite: shared.suite)].isEmpty)
    #expect(try harness.sharedKeychain.readCredential(for: server.id) == "legacy-secret")
    #expect(
      Defaults[.sharedStorageMigrationVersion(suite: shared.suite)] == SharedStorageValidation.currentVersion)
  }

  @Test func migrationNeverWritesSharedTemporaryUnblockRecords() throws {
    let shared = TestDefaults.makeNamedSuite()
    let harness = makeHarness(shared: shared)
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

    try harness.copy.migrate()

    let sharedKey = Defaults.Keys.tempUnblocks(for: server.id, suite: shared.suite).name
    #expect(shared.suite.persistentDomain(forName: shared.name)?[sharedKey] == nil)
    #expect(Defaults[.servers(suite: shared.suite)].map(\.id) == [server.id])
    #expect(Defaults[.tempUnblocks(for: server.id, suite: harness.legacySuite)] == records)
    #expect(
      Defaults[.sharedStorageMigrationVersion(suite: shared.suite)] == SharedStorageValidation.currentVersion)
  }

  private struct Harness {
    let legacySuite: UserDefaults
    let sharedSuite: UserDefaults
    let sharedSuiteName: String
    let legacyKeychain: MockKeychainManager
    let sharedKeychain: MockKeychainManager
    let copy: StorageLegacyCopyEngine
  }

  private func makeHarness(
    legacy: (name: String, suite: UserDefaults) = TestDefaults.makeNamedSuite(),
    shared: (name: String, suite: UserDefaults) = TestDefaults.makeNamedSuite()
  ) -> Harness {
    let legacyKeychain = MockKeychainManager()
    let sharedKeychain = MockKeychainManager()
    return Harness(
      legacySuite: legacy.suite,
      sharedSuite: shared.suite,
      sharedSuiteName: shared.name,
      legacyKeychain: legacyKeychain,
      sharedKeychain: sharedKeychain,
      copy: StorageLegacyCopyEngine(
        legacySuite: legacy.suite,
        legacySuiteName: legacy.name,
        sharedSuite: shared.suite,
        sharedSuiteName: shared.name,
        legacyKeychain: legacyKeychain,
        sharedKeychain: sharedKeychain
      )
    )
  }
}
