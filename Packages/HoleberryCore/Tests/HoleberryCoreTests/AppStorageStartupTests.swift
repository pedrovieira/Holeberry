import Defaults
import Foundation
import Testing

@testable import HoleberryCore

@Suite("AppStorageStartup")
@MainActor
struct AppStorageStartupTests {
  // MARK: - First launches

  @Test func freshInstallStartsOnSharedStorage() throws {
    let harness = StartupHarness()

    let outcome = harness.start()

    guard case .shared(let storage, let activatedNow) = outcome else {
      Issue.record("Expected shared storage on a fresh install")
      return
    }
    #expect(activatedNow)
    #expect(storage.loadServers().isEmpty)
    #expect(outcome.status == .shared)
    #expect(harness.sharedMarker == SharedStorageValidation.currentVersion)
    #expect(harness.activationRecord == SharedStorageValidation.currentVersion)
  }

  @Test func passwordlessServerUpgradeSucceeds() throws {
    let harness = StartupHarness()
    let passwordless = ServerConfig(id: UUID(), label: "Open", url: "http://open.local", version: .v6)
    Defaults[.servers(suite: harness.legacySuite)] = [passwordless]

    let outcome = harness.start()

    guard case .shared(let storage, let activatedNow) = outcome else {
      Issue.record("Expected shared storage after copying a passwordless server")
      return
    }
    #expect(activatedNow)
    #expect(storage.loadServers().map(\.id) == [passwordless.id])
    #expect(try storage.readCredential(for: passwordless.id) == nil)
    #expect(try harness.sharedKeychain.readCredential(for: passwordless.id) == nil)
    #expect(harness.sharedMarker == SharedStorageValidation.currentVersion)
  }

  @Test func upgradeCopiesCredentialBearingServerAndKeepsLegacyOriginals() throws {
    let harness = StartupHarness()
    let server = ServerConfig(id: UUID(), label: "Home", url: "http://home.local", version: .v6)
    Defaults[.servers(suite: harness.legacySuite)] = [server]
    try harness.legacyKeychain.saveCredential("legacy-secret", for: server.id)

    let outcome = harness.start()

    guard case .shared(let storage, let activatedNow) = outcome else {
      Issue.record("Expected shared storage after the first copy")
      return
    }
    #expect(activatedNow)
    #expect(storage.loadServers().map(\.id) == [server.id])
    #expect(try storage.readCredential(for: server.id) == "legacy-secret")
    #expect(try harness.legacyKeychain.readCredential(for: server.id) == "legacy-secret")
    #expect(Defaults[.servers(suite: harness.legacySuite)].map(\.id) == [server.id])
    #expect(harness.activationRecord == SharedStorageValidation.currentVersion)
  }

  // MARK: - Retry after an interrupted copy

  @Test func legacyEditsDuringFallbackRefreshCompletedCopyBeforeActivation() throws {
    let harness = StartupHarness()
    let original = ServerConfig(id: UUID(), label: "Old", url: "http://old.local", version: .v5)
    let removed = ServerConfig(id: UUID(), url: "http://removed.local", version: .v6)
    Defaults[.servers(suite: harness.legacySuite)] = [original, removed]
    try harness.legacyKeychain.saveCredential("old-secret", for: original.id)
    try harness.legacyKeychain.saveCredential("removed-secret", for: removed.id)
    try harness.completeCopyWithoutActivation()
    harness.sharedStorage.locationError = StartupTestError.sharedLocationUnavailable

    let fallback = try #require(harness.start().storage)
    try fallback.removeServer(id: removed.id)
    let edited = ServerConfig(id: original.id, label: "Updated", url: "https://updated.local", version: .v6)
    let added = ServerConfig(id: UUID(), url: "http://added.local", version: .v6)
    fallback.saveServers([edited, added])
    try fallback.saveCredential("updated-secret", for: edited.id)
    try fallback.saveCredential("added-secret", for: added.id)
    harness.sharedStorage.locationError = nil

    let outcome = harness.start()

    guard case .shared(let storage, let activatedNow) = outcome else {
      Issue.record("Expected the completed copy to refresh before activation")
      return
    }
    #expect(activatedNow)
    let servers = storage.loadServers()
    try #require(servers.count == 2)
    #expect(servers.map(\.id) == [edited.id, added.id])
    #expect(servers[0].label == "Updated")
    #expect(servers[0].url == "https://updated.local")
    #expect(servers[0].version == .v6)
    #expect(try storage.readCredential(for: edited.id) == "updated-secret")
    #expect(try storage.readCredential(for: added.id) == "added-secret")
    #expect(try harness.sharedKeychain.readCredential(for: removed.id) == nil)
    #expect(harness.activationRecord == SharedStorageValidation.currentVersion)
  }

  @Test func legacyCredentialRemovalDuringFallbackClearsCompletedSharedCopy() throws {
    let harness = StartupHarness()
    let server = ServerConfig(id: UUID(), url: "http://saved.local", version: .v6)
    Defaults[.servers(suite: harness.legacySuite)] = [server]
    try harness.legacyKeychain.saveCredential("old-secret", for: server.id)
    try harness.completeCopyWithoutActivation()
    harness.sharedStorage.locationError = StartupTestError.sharedLocationUnavailable

    let fallback = try #require(harness.start().storage)
    try fallback.deleteCredential(for: server.id)
    harness.sharedStorage.locationError = nil

    let outcome = harness.start()

    #expect(outcome.status == .shared)
    let storage = try #require(outcome.storage)
    #expect(storage.loadServers().map(\.id) == [server.id])
    #expect(try storage.readCredential(for: server.id) == nil)
  }

  @Test func failedRefreshLeavesCompletedCopyPendingAndRetriesLatestLegacyState() throws {
    let harness = StartupHarness()
    let server = ServerConfig(id: UUID(), url: "http://saved.local", version: .v6)
    Defaults[.servers(suite: harness.legacySuite)] = [server]
    try harness.legacyKeychain.saveCredential("old-secret", for: server.id)
    try harness.completeCopyWithoutActivation()
    try harness.legacyKeychain.saveCredential("updated-secret", for: server.id)
    harness.sharedKeychain.saveErrorStub = StartupTestError.credentialCopyFailed

    let outcome = harness.start()

    guard case .legacy(let storage, let cause) = outcome else {
      Issue.record("Expected validated legacy fallback after the refresh failed")
      return
    }
    #expect(cause as? StartupTestError == .credentialCopyFailed)
    #expect(harness.sharedMarker == 0)
    #expect(harness.activationRecord == 0)
    #expect(
      try SharedStorageValidation.readiness(in: harness.sharedSuite, suiteName: harness.sharedSuiteName) == .pending)
    #expect(try storage.readCredential(for: server.id) == "updated-secret")

    try storage.saveCredential("latest-secret", for: server.id)
    harness.sharedKeychain.saveErrorStub = nil
    let retry = harness.start()

    #expect(retry.status == .shared)
    let refreshed = try #require(retry.storage)
    #expect(try refreshed.readCredential(for: server.id) == "latest-secret")
    #expect(harness.activationRecord == SharedStorageValidation.currentVersion)
    #expect(harness.sharedMarker == SharedStorageValidation.currentVersion)
  }

  @Test func unreadableLegacyDoesNotActivateOrInvalidateCompletedSharedCopy() throws {
    let harness = StartupHarness()
    let server = ServerConfig(id: UUID(), url: "http://saved.local", version: .v6)
    Defaults[.servers(suite: harness.legacySuite)] = [server]
    try harness.legacyKeychain.saveCredential("saved-secret", for: server.id)
    try harness.completeCopyWithoutActivation()
    setRawDefaultsValue("not-an-array", for: Defaults.Keys.servers(suite: harness.legacySuite))

    let outcome = harness.start()

    guard case .setupFailure(let error) = outcome else {
      Issue.record("Expected invalid legacy data to block activation of an older shared copy")
      return
    }
    #expect(error as? SharedStorageMigrationError == .malformedLegacyConfiguration)
    #expect(harness.activationRecord == 0)
    #expect(harness.sharedMarker == SharedStorageValidation.currentVersion)
    #expect(Defaults[.servers(suite: harness.sharedSuite)].map(\.id) == [server.id])
    #expect(try harness.sharedKeychain.readCredential(for: server.id) == "saved-secret")
  }

  @Test(arguments: [false, true])
  func unsupportedSharedVersionDoesNotRefreshLegacy(newer: Bool) {
    let version = newer ? SharedStorageValidation.currentVersion + 1 : -1
    let harness = StartupHarness()
    let legacy = ServerConfig(id: UUID(), url: "http://legacy.local", version: .v5)
    let shared = ServerConfig(id: UUID(), url: "http://shared.local", version: .v6)
    Defaults[.servers(suite: harness.legacySuite)] = [legacy]
    Defaults[.servers(suite: harness.sharedSuite)] = [shared]
    Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] = version

    let outcome = harness.start()

    guard case .setupFailure(let error) = outcome else {
      Issue.record("Expected unsupported shared storage to block migration")
      return
    }
    #expect(error as? SharedStorageReadinessError == .unsupportedCompletionVersion(version))
    #expect(Defaults[.servers(suite: harness.sharedSuite)].map(\.id) == [shared.id])
    #expect(harness.sharedMarker == version)
    #expect(harness.activationRecord == 0)
    #expect(harness.legacyKeychain.readCallCount == 0)
    #expect(harness.sharedStorage.keychainCallCount == 0)
  }

  @Test func interruptedCopyKeepsLegacyStorageAndRetriesSafely() throws {
    let harness = StartupHarness()
    let server = ServerConfig(id: UUID(), label: "Home", url: "http://home.local", version: .v6)
    Defaults[.servers(suite: harness.legacySuite)] = [server]
    try harness.legacyKeychain.saveCredential("legacy-secret", for: server.id)
    harness.sharedKeychain.saveErrorStub = StartupTestError.credentialCopyFailed

    let first = harness.start()

    guard case .legacy(let legacyStorage, let cause) = first else {
      Issue.record("Expected legacy storage while the first copy is pending")
      return
    }
    #expect(cause as? StartupTestError == .credentialCopyFailed)
    #expect(first.status == .legacy)
    #expect(first.activatedNow == false)
    #expect(legacyStorage.loadServers().map(\.id) == [server.id])
    #expect(try legacyStorage.readCredential(for: server.id) == "legacy-secret")
    #expect(harness.sharedMarker == 0)
    #expect(harness.activationRecord == 0)
    #expect(try harness.legacyKeychain.readCredential(for: server.id) == "legacy-secret")

    harness.sharedKeychain.saveErrorStub = nil

    let retry = harness.start()

    guard case .shared(let sharedStorage, let activatedNow) = retry else {
      Issue.record("Expected shared storage after a successful retry")
      return
    }
    #expect(activatedNow)
    #expect(sharedStorage.loadServers().map(\.id) == [server.id])
    #expect(try sharedStorage.readCredential(for: server.id) == "legacy-secret")
    #expect(harness.sharedMarker == SharedStorageValidation.currentVersion)
    #expect(harness.activationRecord == SharedStorageValidation.currentVersion)
  }

  // MARK: - Cutover authority

  @Test func completedCopyNeverReimportsLaterLegacyEdits() throws {
    let harness = StartupHarness()
    let original = ServerConfig(id: UUID(), label: "Home", url: "http://home.local", version: .v6)
    Defaults[.servers(suite: harness.legacySuite)] = [original]
    try harness.legacyKeychain.saveCredential("original-secret", for: original.id)
    guard case .shared = harness.start() else {
      Issue.record("Expected the first launch to complete the copy")
      return
    }

    let late = ServerConfig(id: UUID(), label: "Late", url: "http://late.local", version: .v5)
    Defaults[.servers(suite: harness.legacySuite)] = [original, late]
    try harness.legacyKeychain.saveCredential("late-secret", for: late.id)
    let legacyReadsBefore = harness.legacyKeychain.readCallCount

    let second = harness.start()

    guard case .shared(let storage, let activatedNow) = second else {
      Issue.record("Expected shared storage to stay authoritative")
      return
    }
    #expect(activatedNow == false)
    #expect(storage.loadServers().map(\.id) == [original.id])
    #expect(try storage.readCredential(for: late.id) == nil)
    #expect(harness.legacyKeychain.readCallCount == legacyReadsBefore)
    #expect(harness.sharedMarker == SharedStorageValidation.currentVersion)
  }

  @Test func activatedStoreWithResetSharedDataReportsSetupFailureWithoutReplay() {
    let harness = StartupHarness()
    let server = ServerConfig(id: UUID(), url: "http://legacy.local", version: .v6)
    Defaults[.servers(suite: harness.legacySuite)] = [server]
    Defaults[.sharedStorageActivatedVersion(suite: harness.legacySuite)] = SharedStorageValidation.currentVersion

    let outcome = harness.start()

    guard case .setupFailure(let error) = outcome else {
      Issue.record("Expected a setup failure instead of replaying legacy data")
      return
    }
    #expect(error as? AppStorageStartupError == .completedStoreMarkerMissing)
    #expect(outcome.status == .recovery)
    #expect(outcome.storage == nil)
    #expect(harness.sharedMarker == 0)
    #expect(harness.legacyKeychain.readCallCount == 0)
  }

  @Test func activatedStoreWithUnsupportedSharedVersionReportsSetupFailureWithoutReplay() {
    let harness = StartupHarness()
    let server = ServerConfig(id: UUID(), url: "http://legacy.local", version: .v6)
    Defaults[.servers(suite: harness.legacySuite)] = [server]
    Defaults[.sharedStorageActivatedVersion(suite: harness.legacySuite)] = SharedStorageValidation.currentVersion
    let unsupported = SharedStorageValidation.currentVersion + 1
    harness.sharedSuite.set(
      unsupported,
      forKey: Defaults.Keys.sharedStorageMigrationVersion(suite: harness.sharedSuite).name
    )

    let outcome = harness.start()

    guard case .setupFailure(let error) = outcome else {
      Issue.record("Expected a setup failure for an unsupported completed copy")
      return
    }
    #expect(error as? SharedStorageReadinessError == .unsupportedCompletionVersion(unsupported))
    #expect(outcome.status == .recovery)
    #expect(outcome.storage == nil)
    #expect(harness.sharedMarker == unsupported, "the unsupported evidence stays untouched")
    #expect(harness.legacyKeychain.readCallCount == 0)
  }

  @Test func activatedStoreWithUnreadableSharedServersReportsSetupFailure() {
    let harness = StartupHarness()
    Defaults[.sharedStorageActivatedVersion(suite: harness.legacySuite)] = SharedStorageValidation.currentVersion
    harness.sharedSuite.set(
      SharedStorageValidation.currentVersion,
      forKey: Defaults.Keys.sharedStorageMigrationVersion(suite: harness.sharedSuite).name
    )
    harness.sharedSuite.set(
      "not-an-array",
      forKey: Defaults.Keys.servers(suite: harness.sharedSuite).name
    )

    let outcome = harness.start()

    guard case .setupFailure(let error) = outcome else {
      Issue.record("Expected a setup failure for unreadable shared servers")
      return
    }
    #expect(error as? SharedStorageReadinessError == .malformedServerConfiguration)
    #expect(outcome.storage == nil)
    #expect(harness.legacyKeychain.readCallCount == 0)
  }

  // MARK: - Unreadable or incompatible data

  @Test func unreadableLegacyConfigurationReportsSetupFailure() throws {
    let harness = StartupHarness()
    let key = Defaults.Keys.servers(suite: harness.legacySuite)
    let malformed: [String] = ["not-json"]
    setRawDefaultsValue(malformed, for: key)

    let outcome = harness.start()

    guard case .setupFailure(let error) = outcome else {
      Issue.record("Expected a setup failure for an unreadable legacy list")
      return
    }
    #expect(error as? SharedStorageMigrationError == .malformedLegacyConfiguration)
    #expect(outcome.storage == nil)
    #expect(rawDefaultsValue(for: key) as? [String] == malformed)
    #expect(harness.sharedMarker == 0)
  }

  @Test func floatingPointCompletionMarkerReportsSetupFailure() {
    let harness = StartupHarness()
    harness.sharedSuite.set(
      NSNumber(value: 1.0),
      forKey: Defaults.Keys.sharedStorageMigrationVersion(suite: harness.sharedSuite).name
    )

    let outcome = harness.start()

    guard case .setupFailure(let error) = outcome else {
      Issue.record("Expected a setup failure for a floating-point completion marker")
      return
    }
    #expect(error as? SharedStorageReadinessError == .malformedCompletionVersion)
    #expect(harness.legacyKeychain.readCallCount == 0)
  }

  @Test func unreadableActivationWithReadySharedStoreRepairsRecord() {
    let harness = StartupHarness()
    let legacy = ServerConfig(id: UUID(), url: "http://legacy.local", version: .v5)
    Defaults[.servers(suite: harness.legacySuite)] = [legacy]
    harness.legacySuite.set(
      "current",
      forKey: Defaults.Keys.sharedStorageActivatedVersion(suite: harness.legacySuite).name
    )
    Defaults[.servers(suite: harness.sharedSuite)] = []
    Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] = SharedStorageValidation.currentVersion

    let outcome = harness.start()

    guard case .shared(let storage, let activatedNow) = outcome else {
      Issue.record("Expected verified shared storage to win")
      return
    }
    #expect(activatedNow)
    #expect(storage.loadServers().isEmpty)
    #expect(harness.legacyKeychain.readCallCount == 0)
    #expect(harness.activationRecord == SharedStorageValidation.currentVersion)
  }

  @Test func unreadableActivationWithPendingSharedStoreReportsSetupFailureWithoutMigration() {
    let harness = StartupHarness()
    harness.legacySuite.set(
      "current",
      forKey: Defaults.Keys.sharedStorageActivatedVersion(suite: harness.legacySuite).name
    )

    let outcome = harness.start()

    guard case .setupFailure(let error) = outcome else {
      Issue.record("Expected a setup failure for unreadable history with pending shared data")
      return
    }
    #expect(error as? SharedStorageMigrationError == .malformedActivationRecord)
    #expect(harness.sharedMarker == 0)
    #expect(harness.legacyKeychain.readCallCount == 0)
  }

  @Test func negativeActivationRecordReportsSetupFailureWithoutMigration() {
    let harness = StartupHarness()
    harness.legacySuite.set(
      -1,
      forKey: Defaults.Keys.sharedStorageActivatedVersion(suite: harness.legacySuite).name
    )

    let outcome = harness.start()

    guard case .setupFailure(let error) = outcome else {
      Issue.record("Expected a setup failure for a negative activation record")
      return
    }
    #expect(error as? SharedStorageMigrationError == .malformedActivationRecord)
    #expect(harness.sharedMarker == 0)
  }

  // MARK: - Unavailable shared environment

  @Test func unavailableAppGroupWithoutActivationUsesValidatedLegacyStorage() {
    let harness = StartupHarness()
    let server = ServerConfig(id: UUID(), url: "http://legacy.local", version: .v6)
    Defaults[.servers(suite: harness.legacySuite)] = [server]
    harness.sharedStorage.locationError = StartupTestError.sharedLocationUnavailable

    let outcome = harness.start()

    guard case .legacy(let storage, let cause) = outcome else {
      Issue.record("Expected legacy storage when the App Group is unavailable")
      return
    }
    #expect(cause as? StartupTestError == .sharedLocationUnavailable)
    #expect(storage.loadServers().map(\.id) == [server.id])
    #expect(harness.sharedStorage.keychainCallCount == 0)
  }

  @Test func unavailableAppGroupAfterActivationReportsSetupFailure() {
    let harness = StartupHarness()
    Defaults[.sharedStorageActivatedVersion(suite: harness.legacySuite)] = SharedStorageValidation.currentVersion
    harness.sharedStorage.locationError = StartupTestError.sharedLocationUnavailable

    let outcome = harness.start()

    guard case .setupFailure(let error) = outcome else {
      Issue.record("Expected a setup failure when activated shared storage cannot be reopened")
      return
    }
    #expect(error as? StartupTestError == .sharedLocationUnavailable)
    #expect(outcome.storage == nil)
  }

  @Test func unavailableSharedKeychainAfterActivationReportsSetupFailure() {
    let harness = StartupHarness()
    Defaults[.sharedStorageActivatedVersion(suite: harness.legacySuite)] = SharedStorageValidation.currentVersion
    Defaults[.servers(suite: harness.sharedSuite)] = []
    Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] = SharedStorageValidation.currentVersion
    harness.sharedStorage.keychainError = StartupTestError.sharedKeychainUnavailable

    let outcome = harness.start()

    guard case .setupFailure(let error) = outcome else {
      Issue.record("Expected a setup failure when the shared Keychain is unavailable")
      return
    }
    #expect(error as? StartupTestError == .sharedKeychainUnavailable)
    #expect(harness.activationRecord == SharedStorageValidation.currentVersion)

    harness.sharedStorage.locationError = StartupTestError.sharedLocationUnavailable

    #expect(harness.start().status == .recovery)
  }

  @Test func readySharedStoreWithUnavailableKeychainDoesNotActivateOrBlockLaterLegacyFallback() {
    let harness = StartupHarness()
    let server = ServerConfig(id: UUID(), url: "http://legacy.local", version: .v6)
    Defaults[.servers(suite: harness.legacySuite)] = [server]
    Defaults[.servers(suite: harness.sharedSuite)] = [server]
    Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] = SharedStorageValidation.currentVersion
    harness.sharedStorage.keychainError = StartupTestError.sharedKeychainUnavailable

    let first = harness.start()

    guard case .legacy(let legacyStorage, let error) = first else {
      Issue.record("Expected validated legacy storage before shared storage was activated")
      return
    }
    #expect(error as? StartupTestError == .sharedKeychainUnavailable)
    #expect(legacyStorage.loadServers().map(\.id) == [server.id])
    #expect(harness.sharedMarker == SharedStorageValidation.currentVersion)
    #expect(harness.activationRecord == 0)
    let activationKey = Defaults.Keys.sharedStorageActivatedVersion(suite: harness.legacySuite).name
    #expect(harness.legacySuite.persistentDomain(forName: harness.legacySuiteName)?[activationKey] == nil)

    harness.sharedStorage.locationError = StartupTestError.sharedLocationUnavailable

    let retry = harness.start()

    guard case .legacy(let storage, _) = retry else {
      Issue.record("Expected legacy fallback because shared storage was never activated")
      return
    }
    #expect(storage.loadServers().map(\.id) == [server.id])
  }

  @Test func readySharedStoreWithUnavailableKeychainDoesNotRepairUnreadableActivationRecord() {
    let harness = StartupHarness()
    let activationKey = Defaults.Keys.sharedStorageActivatedVersion(suite: harness.legacySuite).name
    harness.legacySuite.set("current", forKey: activationKey)
    Defaults[.servers(suite: harness.sharedSuite)] = []
    Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] = SharedStorageValidation.currentVersion
    harness.sharedStorage.keychainError = StartupTestError.sharedKeychainUnavailable

    let outcome = harness.start()

    guard case .setupFailure(let error) = outcome else {
      Issue.record("Expected a setup failure when the ready shared Keychain is unavailable")
      return
    }
    #expect(error as? StartupTestError == .sharedKeychainUnavailable)
    #expect(harness.legacySuite.string(forKey: activationKey) == "current")

    harness.sharedStorage.locationError = StartupTestError.sharedLocationUnavailable

    #expect(harness.start().status == .recovery)
  }
}

// MARK: - Test Support

private enum StartupTestError: Error, Equatable {
  case sharedLocationUnavailable
  case sharedKeychainUnavailable
  case credentialCopyFailed
}

@MainActor
private final class StartupHarness {
  let legacySuite: UserDefaults
  let sharedSuite: UserDefaults
  let legacySuiteName: String
  let sharedSuiteName: String
  let legacyKeychain = MockKeychainManager()
  let sharedKeychain = MockKeychainManager()
  let sharedStorage: StubSharedStorage
  let migrator: StorageLegacyMigrator

  init() {
    let legacy = TestDefaults.makeNamedSuite()
    let shared = TestDefaults.makeNamedSuite()
    legacySuite = legacy.suite
    legacySuiteName = legacy.name
    sharedSuite = shared.suite
    sharedSuiteName = shared.name
    sharedStorage = StubSharedStorage(
      location: SharedStorageLocation(suite: shared.suite, suiteName: shared.name),
      keychain: sharedKeychain
    )
    migrator = StorageLegacyMigrator(
      legacySuite: legacy.suite,
      legacySuiteName: legacy.name,
      legacyKeychain: legacyKeychain,
      shared: sharedStorage
    )
  }

  var sharedMarker: Int {
    Defaults[.sharedStorageMigrationVersion(suite: sharedSuite)]
  }

  var activationRecord: Int {
    Defaults[.sharedStorageActivatedVersion(suite: legacySuite)]
  }

  /// Models an interrupted launch after publishing completion but before activation.
  func completeCopyWithoutActivation() throws {
    try StorageLegacyCopyEngine(
      legacySuite: legacySuite,
      legacySuiteName: legacySuiteName,
      sharedSuite: sharedSuite,
      sharedSuiteName: sharedSuiteName,
      legacyKeychain: legacyKeychain,
      sharedKeychain: sharedKeychain
    ).refreshBeforeActivation()
  }

  func start() -> AppStorageStartup.Outcome {
    AppStorageStartup(
      migrator: migrator,
      legacySuite: legacySuite,
      legacySuiteName: legacySuiteName,
      legacyKeychain: legacyKeychain
    ).start()
  }
}

// MARK: - Migration mapping

/// Reference error used to prove cause identity survives startup mapping.
private final class StartupMappingError: Error {}

@MainActor
@Suite("AppStorageStartup migration mapping")
struct AppStorageStartupMigrationMappingTests {
  @MainActor
  private final class Harness {
    let legacy = TestDefaults.makeNamedSuite()
    let keychain = MockKeychainManager()
    let writer = MockConnectionStore()
    let migrator = MockStorageLegacyMigrator()

    var startup: AppStorageStartup {
      AppStorageStartup(
        migrator: migrator,
        legacySuite: legacy.suite,
        legacySuiteName: legacy.name,
        legacyKeychain: keychain
      )
    }

    func storeServer(_ server: ServerConfig, credential: String? = nil) {
      Defaults[.servers(suite: legacy.suite)] = [server]
      if let credential {
        keychain.storedCredentials[server.id.uuidString] = credential
      }
    }
  }

  @Test func alreadyActiveMapsToSharedWithoutActivation() {
    let harness = Harness()
    harness.migrator.resultStub = .success(.alreadyActive(harness.writer))

    let outcome = harness.startup.start()

    guard case .shared(let storage, let activatedNow) = outcome else {
      Issue.record("Expected shared storage")
      return
    }
    #expect(!activatedNow)
    // Hoisted out of #expect: Apple Swift 6.4.0 aborts in SILGen when the
    // macro's autoclosure carries an existential-to-AnyObject conversion thunk.
    let deliversWriter = (storage as AnyObject) === harness.writer
    #expect(deliversWriter)
    #expect(outcome.status == .shared)
    #expect(harness.migrator.runIfNeededCallCount == 1)
  }

  @Test func activatedNowMapsToSharedActivation() {
    let harness = Harness()
    harness.migrator.resultStub = .success(.activatedNow(harness.writer))

    let outcome = harness.startup.start()

    guard case .shared(let storage, let activatedNow) = outcome else {
      Issue.record("Expected shared storage")
      return
    }
    #expect(activatedNow)
    #expect(outcome.activatedNow)
    let deliversWriter = (storage as AnyObject) === harness.writer
    #expect(deliversWriter)
    #expect(harness.migrator.runIfNeededCallCount == 1)
  }

  @Test func beforeActivationUsesValidatedWritableLegacyFallback() throws {
    let harness = Harness()
    let server = ServerConfig(label: "Home", url: "http://home.local", version: .v6)
    harness.storeServer(server, credential: "legacy-secret")
    let cause = StartupMappingError()
    harness.migrator.resultStub = .failure(StorageLegacyMigrationFailure.beforeActivation(cause: cause))

    let outcome = harness.startup.start()

    guard case .legacy(let storage, let problem) = outcome else {
      Issue.record("Expected validated legacy fallback")
      return
    }
    // Hoisted out of #expect for the same Apple Swift 6.4.0 SILGen abort as
    // the writer comparisons above.
    let problemIsCause = (problem as AnyObject) === cause
    #expect(problemIsCause)
    #expect(storage.loadServers().map(\.id) == [server.id])
    #expect(try storage.readCredential(for: server.id) == "legacy-secret")
    #expect(outcome.status == .legacy)
    #expect(harness.migrator.runIfNeededCallCount == 1)
  }

  @Test func beforeActivationWithMalformedLegacyRecovers() {
    let harness = Harness()
    setRawDefaultsValue("not-an-array", for: Defaults.Keys.servers(suite: harness.legacy.suite))
    harness.migrator.resultStub = .failure(
      StorageLegacyMigrationFailure.beforeActivation(cause: StartupMappingError())
    )

    let outcome = harness.startup.start()

    guard case .setupFailure(let error) = outcome else {
      Issue.record("Expected recovery for a malformed legacy list")
      return
    }
    #expect(error as? SharedStorageMigrationError == .malformedLegacyConfiguration)
    #expect(outcome.storage == nil)
    #expect(harness.migrator.runIfNeededCallCount == 1)
  }

  @Test func recoveryRequiredNeverAllowsLegacyFallback() {
    let harness = Harness()
    harness.storeServer(
      ServerConfig(label: "Home", url: "http://home.local", version: .v6), credential: "secret")
    let cause = StartupMappingError()
    harness.migrator.resultStub = .failure(StorageLegacyMigrationFailure.recoveryRequired(cause: cause))

    let outcome = harness.startup.start()

    guard case .setupFailure(let error) = outcome else {
      Issue.record("Expected recovery")
      return
    }
    let errorIsCause = (error as AnyObject) === cause
    #expect(errorIsCause)
    #expect(outcome.status == .recovery)
    #expect(outcome.storage == nil)
    #expect(harness.migrator.runIfNeededCallCount == 1)
  }

  @Test func unexpectedErrorRecoversWithItsOwnCause() {
    let harness = Harness()
    harness.storeServer(
      ServerConfig(label: "Home", url: "http://home.local", version: .v6), credential: "secret")
    let cause = StartupMappingError()
    harness.migrator.resultStub = .failure(cause)

    let outcome = harness.startup.start()

    guard case .setupFailure(let error) = outcome else {
      Issue.record("Expected recovery for an unexpected error")
      return
    }
    let errorIsCause = (error as AnyObject) === cause
    #expect(errorIsCause)
    #expect(outcome.storage == nil)
    #expect(harness.migrator.runIfNeededCallCount == 1)
  }
}
