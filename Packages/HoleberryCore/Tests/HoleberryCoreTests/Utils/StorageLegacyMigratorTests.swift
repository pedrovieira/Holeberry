import Defaults
import Foundation
import Testing

@testable import HoleberryCore

/// Reference error used to prove cause identity survives the migration result.
private final class MigratorTestError: Error {}

private struct MigratorTestValueError: Error, Equatable {}

@MainActor
@Suite("StorageLegacyMigrator")
struct StorageLegacyMigratorTests {
  @MainActor
  private final class Harness {
    let legacy = TestDefaults.makeNamedSuite()
    let shared = TestDefaults.makeNamedSuite()
    let legacyKeychain = MockKeychainManager()
    let sharedKeychain = MockKeychainManager()
    let sharedStorage: StubSharedStorage
    let appLocalSuite = TestDefaults.makeSuite()
    let migrator: StorageLegacyMigrator

    init() {
      sharedStorage = StubSharedStorage(
        location: SharedStorageLocation(suite: shared.suite, suiteName: shared.name),
        keychain: sharedKeychain
      )
      migrator = StorageLegacyMigrator(
        legacySuite: legacy.suite,
        legacySuiteName: legacy.name,
        appLocalSuite: appLocalSuite,
        legacyKeychain: legacyKeychain,
        shared: sharedStorage
      )
    }

    var activationRecord: Int {
      Defaults[.sharedStorageActivatedVersion(suite: legacy.suite)]
    }

    var sharedMarker: Int {
      Defaults[.sharedStorageMigrationVersion(suite: shared.suite)]
    }

    func storeLegacy(_ servers: [ServerConfig], credentials: [UUID: String] = [:]) {
      Defaults[.servers(suite: legacy.suite)] = servers
      for (id, credential) in credentials {
        legacyKeychain.storedCredentials[id.uuidString] = credential
      }
    }

    /// Publishes a completed copy while activation stays zero.
    func completeCopyWithoutActivation() throws {
      try StorageLegacyCopyEngine(
        legacySuite: legacy.suite,
        legacySuiteName: legacy.name,
        sharedSuite: shared.suite,
        sharedSuiteName: shared.name,
        legacyKeychain: legacyKeychain,
        sharedKeychain: sharedKeychain
      ).refreshBeforeActivation()
    }

    func publishCompletedCopy(_ servers: [ServerConfig], credentials: [UUID: String] = [:]) {
      Defaults[.servers(suite: shared.suite)] = servers
      Defaults[.sharedStorageMigrationVersion(suite: shared.suite)] = SharedStorageValidation.currentVersion
      for (id, credential) in credentials {
        sharedKeychain.storedCredentials[id.uuidString] = credential
      }
    }

    func markActivated() {
      Defaults[.sharedStorageActivatedVersion(suite: legacy.suite)] = SharedStorageValidation.currentVersion
    }

    func makeServer(_ label: String, version: ServerVersion = .v6) -> ServerConfig {
      ServerConfig(label: label, url: "http://\(label.lowercased()).local", version: version)
    }

    func failure(_ result: @autoclosure () throws -> StorageLegacyMigrationResult) -> StorageLegacyMigrationFailure? {
      do {
        _ = try result()
        Issue.record("Expected a migration failure")
        return nil
      } catch let failure as StorageLegacyMigrationFailure {
        return failure
      } catch {
        Issue.record("Unexpected error: \(error)")
        return nil
      }
    }
  }

  // MARK: - Already active

  @Test func alreadyActivePreparesTheWriterWithoutReadingLegacy() throws {
    let harness = Harness()
    let server = harness.makeServer("Home")
    harness.markActivated()
    harness.publishCompletedCopy([server], credentials: [server.id: "shared-secret"])
    harness.storeLegacy([harness.makeServer("Legacy")], credentials: [UUID(): "legacy-secret"])

    let result = try harness.migrator.runIfNeeded()

    guard case .alreadyActive(let storage) = result else {
      Issue.record("Expected an already-active result")
      return
    }
    #expect(storage.loadServers().map(\.id) == [server.id])
    #expect(try storage.readCredential(for: server.id) == "shared-secret")
    #expect(harness.legacyKeychain.readCallCount == 0)
    #expect(harness.legacyKeychain.saveCallCount == 0)
  }

  @Test func alreadyActiveWithPendingCopyRequiresRecovery() {
    let harness = Harness()
    harness.markActivated()

    guard case .recoveryRequired(let cause)? = harness.failure(try harness.migrator.runIfNeeded()) else {
      Issue.record("Expected recovery for an activated store with no completion marker")
      return
    }
    #expect(cause as? AppStorageStartupError == .completedStoreMarkerMissing)
    #expect(harness.legacyKeychain.readCallCount == 0)
  }

  @Test func alreadyActiveWithLocationFailureRequiresRecovery() {
    let harness = Harness()
    harness.markActivated()
    harness.sharedStorage.locationError = MigratorTestValueError()

    guard case .recoveryRequired(let cause)? = harness.failure(try harness.migrator.runIfNeeded()) else {
      Issue.record("Expected recovery when the App Group cannot open")
      return
    }
    #expect(cause as? MigratorTestValueError == MigratorTestValueError())
    #expect(harness.legacyKeychain.readCallCount == 0)
  }

  @Test func alreadyActiveWithKeychainFailureRequiresRecovery() {
    let harness = Harness()
    harness.markActivated()
    harness.publishCompletedCopy([harness.makeServer("Home")])
    harness.sharedStorage.keychainError = MigratorTestValueError()

    guard case .recoveryRequired(let cause)? = harness.failure(try harness.migrator.runIfNeeded()) else {
      Issue.record("Expected recovery when the shared keychain cannot resolve")
      return
    }
    #expect(cause as? MigratorTestValueError == MigratorTestValueError())
    #expect(harness.legacyKeychain.readCallCount == 0)
  }

  @Test func alreadyActiveWriterRemovesBothCredentialCopies() throws {
    let harness = Harness()
    let server = harness.makeServer("Home")
    harness.markActivated()
    harness.publishCompletedCopy([server], credentials: [server.id: "shared-secret"])
    harness.legacyKeychain.storedCredentials[server.id.uuidString] = "legacy-secret"

    guard case .alreadyActive(let storage) = try harness.migrator.runIfNeeded() else {
      Issue.record("Expected an already-active result")
      return
    }

    try storage.removeServer(id: server.id)

    #expect(storage.loadServers().isEmpty)
    #expect(harness.sharedKeychain.storedCredentials[server.id.uuidString] == nil)
    #expect(harness.legacyKeychain.storedCredentials[server.id.uuidString] == nil)
  }

  // MARK: - Unreadable history

  @Test func unreadableHistoryRepairsOnlyAfterTheKeychainResolves() throws {
    let harness = Harness()
    let server = harness.makeServer("Home")
    let activationKey = Defaults.Keys.sharedStorageActivatedVersion(suite: harness.legacy.suite).name
    harness.legacy.suite.set("current", forKey: activationKey)
    harness.publishCompletedCopy([server], credentials: [server.id: "shared-secret"])
    let legacyServer = harness.makeServer("Legacy")
    harness.storeLegacy([legacyServer], credentials: [legacyServer.id: "legacy-secret"])
    harness.sharedStorage.keychainError = MigratorTestValueError()

    guard case .recoveryRequired(let cause)? = harness.failure(try harness.migrator.runIfNeeded()) else {
      Issue.record("Expected recovery while the keychain is unavailable")
      return
    }
    #expect(cause as? MigratorTestValueError == MigratorTestValueError())
    #expect(harness.legacy.suite.string(forKey: activationKey) == "current")

    harness.sharedStorage.keychainError = nil
    let result = try harness.migrator.runIfNeeded()

    guard case .activatedNow(let storage) = result else {
      Issue.record("Expected a repaired activation")
      return
    }
    #expect(storage.loadServers().map(\.id) == [server.id], "repair keeps the existing shared copy")
    #expect(Defaults[.servers(suite: harness.legacy.suite)].map(\.id) == [legacyServer.id])
    #expect(harness.activationRecord == SharedStorageValidation.currentVersion)
    #expect(harness.legacyKeychain.readCallCount == 0, "repair never imports legacy data")
  }

  @Test func unreadableHistoryWithPendingCopyRequiresRecovery() {
    let harness = Harness()
    let activationKey = Defaults.Keys.sharedStorageActivatedVersion(suite: harness.legacy.suite).name
    harness.legacy.suite.set("current", forKey: activationKey)

    guard case .recoveryRequired(let cause)? = harness.failure(try harness.migrator.runIfNeeded()) else {
      Issue.record("Expected recovery for unreadable history with a pending copy")
      return
    }
    #expect(cause as? SharedStorageMigrationError == .malformedActivationRecord)
    #expect(harness.sharedMarker == 0)
    #expect(harness.legacy.suite.string(forKey: activationKey) == "current")
  }

  @Test func negativeActivationRecordWithoutCopyRequiresRecovery() {
    let harness = Harness()
    let activationKey = Defaults.Keys.sharedStorageActivatedVersion(suite: harness.legacy.suite).name
    harness.legacy.suite.set(-1, forKey: activationKey)

    guard case .recoveryRequired(let cause)? = harness.failure(try harness.migrator.runIfNeeded()) else {
      Issue.record("Expected recovery for a negative activation record with no valid copy")
      return
    }
    #expect(cause as? SharedStorageMigrationError == .malformedActivationRecord)
    #expect(harness.activationRecord == -1, "the unreadable record stays as evidence")
    #expect(harness.sharedMarker == 0)
    #expect(harness.legacyKeychain.readCallCount == 0)
  }

  @Test func positiveFutureActivationIsPriorCutoverHistory() throws {
    let harness = Harness()
    let server = harness.makeServer("Home")
    harness.legacy.suite.set(
      SharedStorageValidation.currentVersion + 3,
      forKey: Defaults.Keys.sharedStorageActivatedVersion(suite: harness.legacy.suite).name
    )
    harness.publishCompletedCopy([server])

    let result = try harness.migrator.runIfNeeded()

    guard case .alreadyActive(let storage) = result else {
      Issue.record("Expected a positive activation value to mean prior cutover")
      return
    }
    #expect(storage.loadServers().map(\.id) == [server.id])
    #expect(harness.legacyKeychain.readCallCount == 0)
  }

  // MARK: - First activation

  @Test func firstActivationImportsAndRecordsActivationLast() throws {
    let harness = Harness()
    let server = harness.makeServer("Home")
    harness.storeLegacy([server], credentials: [server.id: "legacy-secret"])

    let result = try harness.migrator.runIfNeeded()

    guard case .activatedNow(let storage) = result else {
      Issue.record("Expected a first activation")
      return
    }
    #expect(storage.loadServers().map(\.id) == [server.id])
    #expect(try storage.readCredential(for: server.id) == "legacy-secret")
    #expect(harness.sharedMarker == SharedStorageValidation.currentVersion)
    #expect(harness.activationRecord == SharedStorageValidation.currentVersion)
    #expect(try harness.legacyKeychain.readCredential(for: server.id) == "legacy-secret")
  }

  @Test func completedCopyWithoutActivationRefreshesCurrentLegacyState() throws {
    let harness = Harness()
    let original = harness.makeServer("Old", version: .v5)
    let removed = harness.makeServer("Removed")
    harness.storeLegacy(
      [original, removed],
      credentials: [original.id: "old-secret", removed.id: "removed-secret"]
    )
    try harness.completeCopyWithoutActivation()
    harness.sharedKeychain.storedCredentials[removed.id.uuidString] = "removed-secret"

    let edited = ServerConfig(id: original.id, label: "Updated", url: "https://updated.local", version: .v6)
    let added = harness.makeServer("Added")
    harness.storeLegacy([edited, added], credentials: [original.id: "updated-secret", added.id: "added-secret"])

    let result = try harness.migrator.runIfNeeded()

    guard case .activatedNow(let storage) = result else {
      Issue.record("Expected the completed copy to refresh and activate")
      return
    }
    let servers = storage.loadServers()
    #expect(servers.map(\.id) == [edited.id, added.id])
    #expect(servers.first?.label == "Updated")
    #expect(try storage.readCredential(for: edited.id) == "updated-secret")
    #expect(try storage.readCredential(for: added.id) == "added-secret")
    #expect(harness.sharedKeychain.storedCredentials[removed.id.uuidString] == nil)
    #expect(harness.activationRecord == SharedStorageValidation.currentVersion)
  }

  @Test func firstActivationWithPendingCopyImportsAndActivates() throws {
    let harness = Harness()
    let server = harness.makeServer("Home")
    harness.storeLegacy([server], credentials: [server.id: "legacy-secret"])

    _ = try harness.migrator.runIfNeeded()

    #expect(Defaults[.servers(suite: harness.shared.suite)].map(\.id) == [server.id])
    #expect(try harness.sharedKeychain.readCredential(for: server.id) == "legacy-secret")
  }

  @Test func keychainResolutionFailurePermitsFallbackWithoutWrites() {
    let harness = Harness()
    let server = harness.makeServer("Home")
    harness.storeLegacy([server], credentials: [server.id: "legacy-secret"])
    harness.publishCompletedCopy([server])
    harness.sharedStorage.keychainError = MigratorTestValueError()

    guard case .beforeActivation(let cause)? = harness.failure(try harness.migrator.runIfNeeded()) else {
      Issue.record("Expected fallback eligibility when the shared keychain cannot resolve")
      return
    }
    #expect(cause as? MigratorTestValueError == MigratorTestValueError())
    #expect(harness.sharedMarker == SharedStorageValidation.currentVersion)
    #expect(harness.activationRecord == 0)
    #expect(harness.sharedKeychain.storedCredentials.isEmpty)
  }

  @Test func locationFailurePermitsFallbackWithoutWrites() {
    let harness = Harness()
    let server = harness.makeServer("Home")
    harness.storeLegacy([server], credentials: [server.id: "legacy-secret"])
    harness.sharedStorage.locationError = MigratorTestValueError()

    guard case .beforeActivation(let cause)? = harness.failure(try harness.migrator.runIfNeeded()) else {
      Issue.record("Expected fallback eligibility when the App Group cannot open")
      return
    }
    #expect(cause as? MigratorTestValueError == MigratorTestValueError())
    #expect(harness.sharedMarker == 0)
    #expect(harness.activationRecord == 0)
  }

  @Test func malformedSharedEvidenceRequiresRecoveryWithoutRewritingIt() {
    let harness = Harness()
    harness.storeLegacy([harness.makeServer("Legacy")])
    let key = Defaults.Keys.servers(suite: harness.shared.suite)
    let malformed: [String] = ["not-json"]
    setRawDefaultsValue(malformed, for: key)
    Defaults[.sharedStorageMigrationVersion(suite: harness.shared.suite)] = SharedStorageValidation.currentVersion

    guard case .recoveryRequired(let cause)? = harness.failure(try harness.migrator.runIfNeeded()) else {
      Issue.record("Expected recovery for malformed shared evidence")
      return
    }
    #expect(cause as? SharedStorageReadinessError == .malformedServerConfiguration)
    #expect(rawDefaultsValue(for: key) as? [String] == malformed)
    #expect(harness.activationRecord == 0)
  }

  @Test func unsupportedSharedMarkerRequiresRecovery() {
    let harness = Harness()
    harness.storeLegacy([harness.makeServer("Legacy")])
    let unsupported = SharedStorageValidation.currentVersion + 1
    Defaults[.sharedStorageMigrationVersion(suite: harness.shared.suite)] = unsupported

    guard case .recoveryRequired(let cause)? = harness.failure(try harness.migrator.runIfNeeded()) else {
      Issue.record("Expected recovery for an unsupported shared marker")
      return
    }
    #expect(cause as? SharedStorageReadinessError == .unsupportedCompletionVersion(unsupported))
    #expect(harness.activationRecord == 0)
    #expect(harness.sharedStorage.keychainCallCount == 0)
  }

  @Test func malformedPriorSharedListPermitsFallbackWhileCompletionIsZero() throws {
    let harness = Harness()
    let server = harness.makeServer("Home")
    harness.storeLegacy([server], credentials: [server.id: "legacy-secret"])
    let key = Defaults.Keys.servers(suite: harness.shared.suite)
    let malformed: [String] = ["not-json"]
    setRawDefaultsValue(malformed, for: key)

    guard case .beforeActivation(let cause)? = harness.failure(try harness.migrator.runIfNeeded()) else {
      Issue.record("Expected fallback eligibility for an unpublished malformed prior list")
      return
    }
    #expect(cause as? SharedStorageReadinessError == .malformedServerConfiguration)
    #expect(rawDefaultsValue(for: key) as? [String] == malformed)
    #expect(harness.sharedMarker == 0)
    #expect(harness.activationRecord == 0)
    #expect(try harness.legacyKeychain.readCredential(for: server.id) == "legacy-secret")
  }

  @Test func malformedLegacyOnlyPermitsStartupFallbackValidation() {
    let harness = Harness()
    setRawDefaultsValue("not-an-array", for: Defaults.Keys.servers(suite: harness.legacy.suite))

    guard case .beforeActivation(let cause)? = harness.failure(try harness.migrator.runIfNeeded()) else {
      Issue.record("Expected fallback eligibility for a malformed legacy list")
      return
    }
    #expect(cause as? SharedStorageMigrationError == .malformedLegacyConfiguration)
    #expect(harness.sharedMarker == 0)
    #expect(harness.activationRecord == 0)
    #expect(harness.sharedKeychain.storedCredentials.isEmpty)
  }

  @Test func credentialCopyFailureStaysRetryable() throws {
    let harness = Harness()
    let server = harness.makeServer("Home")
    harness.storeLegacy([server], credentials: [server.id: "legacy-secret"])
    harness.sharedKeychain.saveErrorStub = MigratorTestValueError()

    guard case .beforeActivation(let cause)? = harness.failure(try harness.migrator.runIfNeeded()) else {
      Issue.record("Expected fallback eligibility when the credential copy fails")
      return
    }
    #expect(cause as? MigratorTestValueError == MigratorTestValueError())
    #expect(harness.sharedMarker == 0)
    #expect(harness.activationRecord == 0)
    #expect(try harness.legacyKeychain.readCredential(for: server.id) == "legacy-secret")

    harness.sharedKeychain.saveErrorStub = nil
    let result = try harness.migrator.runIfNeeded()

    guard case .activatedNow(let storage) = result else {
      Issue.record("Expected the retry to activate")
      return
    }
    #expect(try storage.readCredential(for: server.id) == "legacy-secret")
    #expect(harness.activationRecord == SharedStorageValidation.currentVersion)
  }

  @Test func repeatCallsReturnAlreadyActiveWithoutImportingLegacy() throws {
    let harness = Harness()
    let server = harness.makeServer("Home")
    harness.storeLegacy([server], credentials: [server.id: "legacy-secret"])
    _ = try harness.migrator.runIfNeeded()
    let legacyReadsAfterActivation = harness.legacyKeychain.readCallCount

    let late = harness.makeServer("Late")
    harness.legacyKeychain.storedCredentials[late.id.uuidString] = "late-secret"
    Defaults[.servers(suite: harness.legacy.suite)] = [server, late]

    let repeatResult = try harness.migrator.runIfNeeded()

    guard case .alreadyActive(let storage) = repeatResult else {
      Issue.record("Expected the second call to report an already-active store")
      return
    }
    #expect(storage.loadServers().map(\.id) == [server.id])
    #expect(harness.legacyKeychain.readCallCount == legacyReadsAfterActivation)
    #expect(harness.activationRecord == SharedStorageValidation.currentVersion)
  }

  @Test func restoredWriterClearingAPasswordKeepsTheLegacyCopy() throws {
    let harness = Harness()
    let server = harness.makeServer("Home")
    harness.storeLegacy([server], credentials: [server.id: "legacy-secret"])
    harness.legacyKeychain.storedCredentials[server.id.uuidString] = "legacy-secret"

    let result = try harness.migrator.runIfNeeded()
    guard case .activatedNow(let storage) = result else {
      Issue.record("Expected a first activation")
      return
    }

    try storage.deleteCredential(for: server.id)

    #expect(harness.sharedKeychain.storedCredentials[server.id.uuidString] == nil)
    #expect(harness.legacyKeychain.storedCredentials[server.id.uuidString] == "legacy-secret")
  }
}
