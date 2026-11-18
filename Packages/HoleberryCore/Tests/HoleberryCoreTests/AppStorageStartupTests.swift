import Defaults
import Foundation
import Testing

@testable import HoleberryCore

@Suite("AppStorageStartup")
@MainActor
struct AppStorageStartupTests {
  @Test func pendingStoreMigratesThenUsesSharedAndActivates() {
    let probe = StartupProbe(suite: TestDefaults.makeSuite())
    probe.readiness = .success(.pending)
    probe.readinessAfterMigration = .success(.ready)

    let selection = probe.select(activatedVersion: 0)

    guard case .useShared(let selected, let didActivate) = selection else {
      Issue.record("Expected shared storage")
      return
    }
    #expect(selected === probe.suite)
    #expect(didActivate)
    #expect(probe.migrationCount == 1)
    #expect(probe.activationCount == 1)
  }

  @Test func firstCopyFailureUsesLegacyWithoutActivation() {
    let probe = StartupProbe(suite: TestDefaults.makeSuite())
    probe.readiness = .success(.pending)
    probe.readinessAfterMigration = .success(.pending)
    probe.migrationError = AppStorageStartupTestError.migrationFailed

    let selection = probe.select(activatedVersion: 0)

    guard case .useLegacy(let cause) = selection else {
      Issue.record("Expected legacy storage")
      return
    }
    #expect(cause as? AppStorageStartupTestError == .migrationFailed)
    #expect(probe.migrationCount == 1)
    #expect(probe.activationCount == 0)
  }

  @Test func verifiedMarkerAfterFailedCopyTakesPrecedence() {
    let probe = StartupProbe(suite: TestDefaults.makeSuite())
    probe.readiness = .success(.pending)
    probe.readinessAfterMigration = .success(.ready)
    probe.migrationError = AppStorageStartupTestError.migrationFailed

    let selection = probe.select(activatedVersion: 0)

    guard case .useShared(let selected, let didActivate) = selection else {
      Issue.record("Expected shared storage")
      return
    }
    #expect(selected === probe.suite)
    #expect(didActivate)
    #expect(probe.activationCount == 1)
  }

  @Test func resolverFailureWithoutEarlierActivationUsesLegacy() {
    let probe = StartupProbe(suite: TestDefaults.makeSuite())
    probe.resolveError = AppStorageStartupTestError.resolutionFailed

    let selection = probe.select(activatedVersion: 0)

    guard case .useLegacy(let cause) = selection else {
      Issue.record("Expected legacy storage")
      return
    }
    #expect(cause as? AppStorageStartupTestError == .resolutionFailed)
    #expect(probe.migrationCount == 0)
    #expect(probe.activationCount == 0)
  }

  @Test func resolverFailureWithEarlierActivationIsUnavailable() {
    let probe = StartupProbe(suite: TestDefaults.makeSuite())
    probe.resolveError = AppStorageStartupTestError.resolutionFailed

    let selection = probe.select(activatedVersion: SharedStorageMigration.currentVersion)

    guard case .unavailable(let cause) = selection else {
      Issue.record("Expected recovery")
      return
    }
    #expect(cause as? AppStorageStartupTestError == .resolutionFailed)
    #expect(probe.migrationCount == 0)
    #expect(probe.activationCount == 0)
  }

  @Test func readyStoreWithoutLocalActivationRecordsActivation() {
    let probe = StartupProbe(suite: TestDefaults.makeSuite())
    probe.readiness = .success(.ready)
    probe.activationError = AppStorageStartupTestError.activationNotPersisted

    let selection = probe.select(activatedVersion: 0)

    guard case .unavailable(let cause) = selection else {
      Issue.record("Expected recovery when the activation record cannot be verified")
      return
    }
    #expect(cause as? AppStorageStartupTestError == .activationNotPersisted)
    #expect(probe.migrationCount == 0)
    #expect(probe.activationCount == 1)
  }

  @Test func readyStoreWithEarlierActivationSkipsMigrationAndActivation() {
    let probe = StartupProbe(suite: TestDefaults.makeSuite())
    probe.readiness = .success(.ready)

    let selection = probe.select(activatedVersion: SharedStorageMigration.currentVersion)

    guard case .useShared(let selected, let didActivate) = selection else {
      Issue.record("Expected shared storage")
      return
    }
    #expect(selected === probe.suite)
    #expect(didActivate == false)
    #expect(probe.migrationCount == 0)
    #expect(probe.activationCount == 0)
  }

  @Test func newerActivationWithResetSharedSuiteIsUnavailableWithoutReplay() {
    let probe = StartupProbe(suite: TestDefaults.makeSuite())
    probe.readiness = .success(.pending)
    probe.readinessAfterMigration = .success(.ready)

    let selection = probe.select(activatedVersion: SharedStorageMigration.currentVersion + 1)

    guard case .unavailable = selection else {
      Issue.record("Expected recovery instead of replaying legacy data")
      return
    }
    #expect(probe.migrationCount == 0)
    #expect(probe.activationCount == 0)
  }

  @Test func writeAccessAndStatusFollowTheSelection() {
    let suite = TestDefaults.makeSuite()
    let shared = AppStorageStartupSelection.useShared(suite, didActivate: false)
    let legacy = AppStorageStartupSelection.useLegacy(cause: AppStorageStartupTestError.migrationFailed)
    let recovery = AppStorageStartupSelection.unavailable(
      cause: AppStorageStartupTestError.resolutionFailed
    )

    #expect(shared.status == .shared)
    #expect(shared.allowsServerChanges)
    #expect(legacy.status == .legacy)
    #expect(legacy.allowsServerChanges)
    #expect(recovery.status == .recovery)
    #expect(recovery.allowsServerChanges == false)
  }

  @Test func earlierActivationWithResetSharedSuiteIsUnavailableWithoutReplay() {
    let probe = StartupProbe(suite: TestDefaults.makeSuite())
    probe.readiness = .success(.pending)
    probe.readinessAfterMigration = .success(.ready)

    let selection = probe.select(activatedVersion: SharedStorageMigration.currentVersion)

    guard case .unavailable = selection else {
      Issue.record("Expected recovery instead of replaying legacy data")
      return
    }
    #expect(probe.migrationCount == 0)
    #expect(probe.activationCount == 0)
  }

  @Test func invalidSharedStoreIsUnavailableWithOrWithoutActivation() {
    for activatedVersion in [0, SharedStorageMigration.currentVersion] {
      let probe = StartupProbe(suite: TestDefaults.makeSuite())
      probe.readiness = .failure(
        SharedStorageReadinessError.unsupportedCompletionVersion(
          SharedStorageMigration.currentVersion + 1
        )
      )

      let selection = probe.select(activatedVersion: activatedVersion)

      guard case .unavailable = selection else {
        Issue.record("Expected recovery for an unsupported shared store")
        return
      }
      #expect(probe.migrationCount == 0)
      #expect(probe.activationCount == 0)
    }
  }

  @Test func activationRetryAfterSuccessfulImportRequestsWidgetReload() {
    let probe = StartupProbe(suite: TestDefaults.makeSuite())
    probe.readiness = .success(.pending)
    probe.readinessAfterMigration = .success(.ready)
    probe.activationError = AppStorageStartupTestError.activationNotPersisted

    let selection = probe.select(activatedVersion: 0)

    guard case .unavailable(let cause) = selection else {
      Issue.record("Expected recovery when the activation record cannot be verified")
      return
    }
    #expect(cause as? AppStorageStartupTestError == .activationNotPersisted)
    #expect(probe.migrationCount == 1)
    #expect(probe.activationCount == 1)

    probe.readiness = .success(.ready)
    probe.activationError = nil

    let retry = probe.select(activatedVersion: 0)

    guard case .useShared(let selected, let shouldReloadWidgets) = retry else {
      Issue.record("Expected shared storage after recording activation")
      return
    }
    #expect(selected === probe.suite)
    #expect(shouldReloadWidgets)
    #expect(probe.migrationCount == 1)
    #expect(probe.activationCount == 2)
  }

  @Test func retryAfterFailedCopyImportsEditedLegacyConnection() throws {
    let legacySuite = TestUserDefaults()
    let sharedSuite = TestUserDefaults()
    let legacyKeychain = MockKeychainManager()
    let sharedKeychain = MockKeychainManager()
    let server = ServerConfig(id: UUID(), label: "Original", url: "http://pihole.local", version: .v6)
    Defaults[.servers(suite: legacySuite)] = [server]
    try legacyKeychain.saveCredential("legacy-secret", for: server.id)
    sharedSuite.rejectedWriteKeys = [Defaults.Keys.servers(suite: sharedSuite).name]

    let migration = SharedStorageMigration(
      legacySuite: legacySuite,
      sharedSuite: sharedSuite,
      sharedSuiteName: sharedSuite.domainName,
      legacyKeychain: legacyKeychain,
      sharedKeychain: sharedKeychain
    )
    var migrationCount = 0
    var activationCount = 0

    func select() -> AppStorageStartupSelection {
      AppStorageStartup.select(
        readActivatedVersion: {
          try SharedStorageMigration.activatedVersion(
            in: legacySuite,
            suiteName: legacySuite.domainName
          )
        },
        resolve: { sharedSuite },
        readReadiness: { suite in
          try SharedStorageMigration.readiness(in: suite, suiteName: sharedSuite.domainName)
        },
        migrate: { _ in
          migrationCount += 1
          try migration.migrate()
        },
        markActivated: {
          activationCount += 1
          try SharedStorageMigration.markActivated(
            in: legacySuite,
            suiteName: legacySuite.domainName
          )
        }
      )
    }

    guard case .useLegacy = select() else {
      Issue.record("Expected legacy storage after a failed first copy")
      return
    }
    #expect(migrationCount == 1)
    #expect(activationCount == 0)
    #expect(Defaults[.servers(suite: sharedSuite)].isEmpty)
    #expect(Defaults[.sharedStorageActivatedVersion(suite: legacySuite)] == 0)

    var edited = server
    edited.label = "Edited"
    Defaults[.servers(suite: legacySuite)] = [edited]
    sharedSuite.rejectedWriteKeys = []

    guard case .useShared(let selected, let didActivate) = select() else {
      Issue.record("Expected shared storage after a successful retry")
      return
    }
    #expect(selected === sharedSuite)
    #expect(didActivate)
    #expect(migrationCount == 2)
    #expect(activationCount == 1)
    #expect(Defaults[.servers(suite: sharedSuite)].map(\.label) == ["Edited"])
    #expect(try sharedKeychain.readCredential(for: server.id) == "legacy-secret")
    let activationKey = Defaults.Keys.sharedStorageActivatedVersion(suite: legacySuite).name
    #expect(
      legacySuite.persistentDomain(forName: legacySuite.domainName)?[activationKey] as? Int
        == SharedStorageMigration.currentVersion
    )
  }

  @Test func malformedActivationWithVerifiedSharedStoreRepairsRecord() {
    let probe = StartupProbe(suite: TestDefaults.makeSuite())
    probe.readiness = .success(.ready)

    let selection = probe.select(readActivatedVersion: { throw AppStorageStartupTestError.activationUnreadable })

    guard case .useShared(let selected, let didActivate) = selection else {
      Issue.record("Expected verified shared storage to win")
      return
    }
    #expect(selected === probe.suite)
    #expect(didActivate)
    #expect(probe.migrationCount == 0)
    #expect(probe.activationCount == 1)
  }

  @Test func malformedActivationWithFailedRepairIsUnavailable() {
    let probe = StartupProbe(suite: TestDefaults.makeSuite())
    probe.readiness = .success(.ready)
    probe.activationError = AppStorageStartupTestError.activationNotPersisted

    let selection = probe.select(readActivatedVersion: { throw AppStorageStartupTestError.activationUnreadable })

    guard case .unavailable = selection else {
      Issue.record("Expected recovery when the activation repair cannot be verified")
      return
    }
    #expect(probe.migrationCount == 0)
    #expect(probe.activationCount == 1)
  }

  @Test func malformedActivationWithPendingSharedStoreIsUnavailableWithoutMigration() {
    let probe = StartupProbe(suite: TestDefaults.makeSuite())
    probe.readiness = .success(.pending)

    let selection = probe.select(readActivatedVersion: { throw AppStorageStartupTestError.activationUnreadable })

    guard case .unavailable(let cause) = selection else {
      Issue.record("Expected recovery for malformed history with pending shared data")
      return
    }
    #expect(cause as? AppStorageStartupTestError == .activationUnreadable)
    #expect(probe.migrationCount == 0)
    #expect(probe.activationCount == 0)
  }

  @Test func malformedActivationWithUnresolvableSuiteIsUnavailable() {
    let probe = StartupProbe(suite: TestDefaults.makeSuite())
    probe.resolveError = AppStorageStartupTestError.resolutionFailed

    let selection = probe.select(readActivatedVersion: { throw AppStorageStartupTestError.activationUnreadable })

    guard case .unavailable(let cause) = selection else {
      Issue.record("Expected recovery when neither shared storage nor history verifies")
      return
    }
    #expect(cause as? AppStorageStartupTestError == .resolutionFailed)
    #expect(probe.migrationCount == 0)
    #expect(probe.activationCount == 0)
  }

  @Test func negativePersistedActivationWithPendingSharedStoreIsUnavailableWithoutMigration() {
    let legacySuite = TestUserDefaults()
    let sharedSuite = TestUserDefaults()
    let activationKey = Defaults.Keys.sharedStorageActivatedVersion(suite: legacySuite).name
    legacySuite.set(-1, forKey: activationKey)
    var migrationCount = 0
    var activationCount = 0

    let selection = AppStorageStartup.select(
      readActivatedVersion: {
        try SharedStorageMigration.activatedVersion(in: legacySuite, suiteName: legacySuite.domainName)
      },
      resolve: { sharedSuite },
      readReadiness: { suite in
        try SharedStorageMigration.readiness(in: suite, suiteName: sharedSuite.domainName)
      },
      migrate: { _ in migrationCount += 1 },
      markActivated: { activationCount += 1 }
    )

    guard case .unavailable = selection else {
      Issue.record("Expected recovery for a negative activation record")
      return
    }
    #expect(migrationCount == 0)
    #expect(activationCount == 0)
  }

  @Test func unavailableDefaultsRejectPrimitiveAndTypedWritesInTheirOwnSuite() throws {
    let (name, control) = TestDefaults.makeNamedSuite()
    let unavailable = try #require(UnavailableDefaults(suiteName: name))

    let sentinel = ServerConfig(id: UUID(), url: "http://sentinel.local", version: .v6)
    let sentinelRecord = TempUnblockRecord(
      domain: "sentinel.example",
      uuid: UUID().uuidString,
      startDateUTC: Date(timeIntervalSince1970: 500),
      durationSeconds: 60
    )
    Defaults[.servers(suite: control)] = [sentinel]
    Defaults[.tempUnblocks(for: sentinel.id, suite: control)] = [sentinelRecord]
    control.set(["saved"], forKey: "savedProbe")
    control.set(["kept"], forKey: "removalProbe")
    let seededDomain = try #require(control.persistentDomain(forName: name))

    let server = ServerConfig(id: UUID(), url: "http://unavailable.local", version: .v6)
    Defaults[.servers(suite: unavailable)] = [server]
    Defaults[.tempUnblocks(for: server.id, suite: unavailable)] = [
      TempUnblockRecord(
        domain: "ads.example",
        uuid: UUID().uuidString,
        startDateUTC: Date(timeIntervalSince1970: 1_000),
        durationSeconds: 300
      )
    ]
    let registrationProbe = "registrationProbe-\(UUID().uuidString)"
    unavailable.set(["leaked"], forKey: "savedProbe")
    unavailable.set(["leaked"], forKey: "typedProbe")
    unavailable.register(defaults: [registrationProbe: "registered"])

    // Both objects use the same named suite, so a write that escapes the
    // override shows up here. Inspect before the removal below could undo it.
    #expect(control.persistentDomain(forName: name) as NSDictionary? == seededDomain as NSDictionary?)
    #expect(control.object(forKey: "savedProbe") as? [String] == ["saved"])
    #expect(control.object(forKey: "typedProbe") == nil)
    // The registration domain is volatile, so check the unavailable instance itself.
    #expect(unavailable.volatileDomain(forName: UserDefaults.registrationDomain)[registrationProbe] == nil)

    unavailable.removeObject(forKey: "removalProbe")
    #expect(control.object(forKey: "removalProbe") as? [String] == ["kept"])

    #expect(Defaults[.servers(suite: unavailable)].isEmpty)
    #expect(Defaults[.tempUnblocks(for: server.id, suite: unavailable)].isEmpty)
  }

  @Test func unavailableKeychainRejectsAllOperations() {
    let keychain = UnavailableKeychain()
    let id = UUID()

    #expect(throws: UnavailableKeychainError.storageUnavailable) {
      try keychain.saveCredential("secret", for: id)
    }
    #expect(throws: UnavailableKeychainError.storageUnavailable) {
      try keychain.readCredential(for: id)
    }
    #expect(throws: UnavailableKeychainError.storageUnavailable) {
      try keychain.deleteCredential(for: id)
    }
  }
}

@MainActor
private final class StartupProbe {
  let suite: UserDefaults
  var resolveError: (any Error)?
  var readiness: Result<SharedStorageReadiness, any Error> = .success(.pending)
  var readinessAfterMigration: Result<SharedStorageReadiness, any Error>?
  var migrationError: (any Error)?
  var activationError: (any Error)?
  private(set) var readinessCallCount = 0
  private(set) var migrationCount = 0
  private(set) var activationCount = 0

  init(suite: UserDefaults) {
    self.suite = suite
  }

  func select(activatedVersion: Int) -> AppStorageStartupSelection {
    select(readActivatedVersion: { activatedVersion })
  }

  func select(readActivatedVersion: () throws -> Int) -> AppStorageStartupSelection {
    AppStorageStartup.select(
      readActivatedVersion: readActivatedVersion,
      resolve: {
        if let resolveError { throw resolveError }
        return suite
      },
      readReadiness: { _ in
        readinessCallCount += 1
        let result = readinessCallCount > 1 ? (readinessAfterMigration ?? readiness) : readiness
        return try result.get()
      },
      migrate: { _ in
        migrationCount += 1
        if let migrationError { throw migrationError }
      },
      markActivated: {
        activationCount += 1
        if let activationError { throw activationError }
      }
    )
  }
}

private enum AppStorageStartupTestError: Error, Equatable {
  case resolutionFailed
  case migrationFailed
  case activationNotPersisted
  case activationUnreadable
}
