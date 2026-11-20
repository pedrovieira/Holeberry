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
    #expect(harness.sharedMarker == SharedStorageMigration.currentVersion)
    #expect(harness.activationRecord == SharedStorageMigration.currentVersion)
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
    #expect(harness.sharedMarker == SharedStorageMigration.currentVersion)
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
    #expect(harness.activationRecord == SharedStorageMigration.currentVersion)
  }

  // MARK: - Retry after an interrupted copy

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
    #expect(harness.sharedMarker == SharedStorageMigration.currentVersion)
    #expect(harness.activationRecord == SharedStorageMigration.currentVersion)
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
    #expect(harness.sharedMarker == SharedStorageMigration.currentVersion)
  }

  @Test func activatedStoreWithResetSharedDataReportsSetupFailureWithoutReplay() {
    let harness = StartupHarness()
    let server = ServerConfig(id: UUID(), url: "http://legacy.local", version: .v6)
    Defaults[.servers(suite: harness.legacySuite)] = [server]
    Defaults[.sharedStorageActivatedVersion(suite: harness.legacySuite)] = SharedStorageMigration.currentVersion

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

  @Test func activatedStoreWithUnreadableSharedServersReportsSetupFailure() {
    let harness = StartupHarness()
    Defaults[.sharedStorageActivatedVersion(suite: harness.legacySuite)] = SharedStorageMigration.currentVersion
    harness.sharedSuite.set(
      SharedStorageMigration.currentVersion,
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
    harness.legacySuite.set(
      "current",
      forKey: Defaults.Keys.sharedStorageActivatedVersion(suite: harness.legacySuite).name
    )
    Defaults[.servers(suite: harness.sharedSuite)] = []
    Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] = SharedStorageMigration.currentVersion

    let outcome = harness.start()

    guard case .shared(_, let activatedNow) = outcome else {
      Issue.record("Expected verified shared storage to win")
      return
    }
    #expect(activatedNow)
    #expect(harness.activationRecord == SharedStorageMigration.currentVersion)
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
    Defaults[.sharedStorageActivatedVersion(suite: harness.legacySuite)] = SharedStorageMigration.currentVersion
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
    Defaults[.sharedStorageActivatedVersion(suite: harness.legacySuite)] = SharedStorageMigration.currentVersion
    Defaults[.servers(suite: harness.sharedSuite)] = []
    Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] = SharedStorageMigration.currentVersion
    harness.sharedStorage.keychainError = StartupTestError.sharedKeychainUnavailable

    let outcome = harness.start()

    guard case .setupFailure(let error) = outcome else {
      Issue.record("Expected a setup failure when the shared Keychain is unavailable")
      return
    }
    #expect(error as? StartupTestError == .sharedKeychainUnavailable)
    #expect(harness.activationRecord == SharedStorageMigration.currentVersion)

    harness.sharedStorage.locationError = StartupTestError.sharedLocationUnavailable

    #expect(harness.start().status == .recovery)
  }

  @Test func readySharedStoreWithUnavailableKeychainDoesNotActivateOrBlockLaterLegacyFallback() {
    let harness = StartupHarness()
    let server = ServerConfig(id: UUID(), url: "http://legacy.local", version: .v6)
    Defaults[.servers(suite: harness.legacySuite)] = [server]
    Defaults[.servers(suite: harness.sharedSuite)] = [server]
    Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] = SharedStorageMigration.currentVersion
    harness.sharedStorage.keychainError = StartupTestError.sharedKeychainUnavailable

    let first = harness.start()

    guard case .setupFailure(let error) = first else {
      Issue.record("Expected a setup failure when the ready shared Keychain is unavailable")
      return
    }
    #expect(error as? StartupTestError == .sharedKeychainUnavailable)
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
    Defaults[.sharedStorageMigrationVersion(suite: harness.sharedSuite)] = SharedStorageMigration.currentVersion
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
  }

  var sharedMarker: Int {
    Defaults[.sharedStorageMigrationVersion(suite: sharedSuite)]
  }

  var activationRecord: Int {
    Defaults[.sharedStorageActivatedVersion(suite: legacySuite)]
  }

  func start() -> AppStorageStartup.Outcome {
    AppStorageStartup(
      legacySuite: legacySuite,
      legacySuiteName: legacySuiteName,
      appLocalSuite: legacySuite,
      legacyKeychain: legacyKeychain,
      sharedStorage: sharedStorage
    ).start()
  }
}
