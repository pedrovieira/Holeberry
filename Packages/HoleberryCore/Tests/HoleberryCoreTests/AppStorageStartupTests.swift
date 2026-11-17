import Defaults
import Foundation
import Testing

@testable import HoleberryCore

@Suite("AppStorageStartup")
@MainActor
struct AppStorageStartupTests {
  @Test func firstMigrationSuccessUsesResolvedSuiteAndActivates() {
    let suite = TestDefaults.makeSuite()
    var migrationCount = 0
    var activated = false

    let selection = AppStorageStartup.select(
      isCurrentMigrationActivated: false,
      resolve: { suite },
      migrate: { resolved in
        migrationCount += 1
        #expect(resolved === suite)
      },
      markActivated: { activated = true }
    )

    guard case .useShared(let selected, let didMigrate) = selection else {
      Issue.record("Expected shared storage")
      return
    }
    #expect(selected === suite)
    #expect(didMigrate)
    #expect(migrationCount == 1)
    #expect(activated)
  }

  @Test func resolverFailureIsUnavailableWithoutMigrationOrActivation() {
    var migrationCount = 0
    var activated = false

    let selection = AppStorageStartup.select(
      isCurrentMigrationActivated: false,
      resolve: { throw AppStorageStartupTestError.resolutionFailed },
      migrate: { _ in migrationCount += 1 },
      markActivated: { activated = true }
    )

    guard case .unavailable(let cause) = selection else {
      Issue.record("Expected unavailable storage")
      return
    }
    #expect(cause as? AppStorageStartupTestError == .resolutionFailed)
    #expect(migrationCount == 0)
    #expect(activated == false)
  }

  @Test func migrationFailureIsUnavailableWithoutLegacyFallback() {
    let suite = TestDefaults.makeSuite()
    let server = ServerConfig(id: UUID(), url: "http://shared.local", version: .v6)
    Defaults[.servers(suite: suite)] = [server]
    var activated = false

    let selection = AppStorageStartup.select(
      isCurrentMigrationActivated: false,
      resolve: { suite },
      migrate: { _ in throw AppStorageStartupTestError.migrationFailed },
      markActivated: { activated = true }
    )

    guard case .unavailable(let cause) = selection else {
      Issue.record("Expected unavailable storage")
      return
    }
    #expect(cause as? AppStorageStartupTestError == .migrationFailed)
    #expect(activated == false)
    #expect(Defaults[.servers(suite: suite)].map(\.id) == [server.id])
  }

  @Test func activatedResolutionFailureIsUnavailableWithoutMigration() {
    var migrationCount = 0
    var activated = false

    let selection = AppStorageStartup.select(
      isCurrentMigrationActivated: true,
      resolve: { throw AppStorageStartupTestError.resolutionFailed },
      migrate: { _ in migrationCount += 1 },
      markActivated: { activated = true }
    )

    guard case .unavailable(let cause) = selection else {
      Issue.record("Expected unavailable storage")
      return
    }
    #expect(cause as? AppStorageStartupTestError == .resolutionFailed)
    #expect(migrationCount == 0)
    #expect(activated == false)
  }

  @Test func activatedResolutionSuccessUsesSharedWithoutMigration() {
    let suite = TestDefaults.makeSuite()
    var migrationCount = 0
    var activated = false

    let selection = AppStorageStartup.select(
      isCurrentMigrationActivated: true,
      resolve: { suite },
      migrate: { _ in migrationCount += 1 },
      markActivated: { activated = true }
    )

    guard case .useShared(let selected, let didMigrate) = selection else {
      Issue.record("Expected shared storage")
      return
    }
    #expect(selected === suite)
    #expect(didMigrate == false)
    #expect(migrationCount == 0)
    #expect(activated == false)
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

private enum AppStorageStartupTestError: Error, Equatable {
  case resolutionFailed
  case migrationFailed
}
