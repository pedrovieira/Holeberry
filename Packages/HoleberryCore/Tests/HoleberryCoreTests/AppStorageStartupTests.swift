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
      isActivated: false,
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
      isActivated: false,
      resolve: { throw AppStorageStartupTestError.resolutionFailed },
      migrate: { _ in migrationCount += 1 },
      markActivated: { activated = true }
    )

    guard case .unavailable = selection else {
      Issue.record("Expected unavailable storage")
      return
    }
    #expect(migrationCount == 0)
    #expect(activated == false)
  }

  @Test func migrationFailureIsUnavailableWithoutLegacyFallback() {
    let suite = TestDefaults.makeSuite()
    let server = ServerConfig(id: UUID(), url: "http://shared.local", version: .v6)
    Defaults[.servers(suite: suite)] = [server]
    var activated = false

    let selection = AppStorageStartup.select(
      isActivated: false,
      resolve: { suite },
      migrate: { _ in throw AppStorageStartupTestError.migrationFailed },
      markActivated: { activated = true }
    )

    guard case .unavailable = selection else {
      Issue.record("Expected unavailable storage")
      return
    }
    #expect(activated == false)
    #expect(Defaults[.servers(suite: suite)].map(\.id) == [server.id])
  }

  @Test func activatedResolutionFailureIsUnavailableWithoutMigration() {
    var migrationCount = 0
    var activated = false

    let selection = AppStorageStartup.select(
      isActivated: true,
      resolve: { throw AppStorageStartupTestError.resolutionFailed },
      migrate: { _ in migrationCount += 1 },
      markActivated: { activated = true }
    )

    guard case .unavailable = selection else {
      Issue.record("Expected unavailable storage")
      return
    }
    #expect(migrationCount == 0)
    #expect(activated == false)
  }

  @Test func activatedResolutionSuccessUsesSharedWithoutMigration() {
    let suite = TestDefaults.makeSuite()
    var migrationCount = 0
    var activated = false

    let selection = AppStorageStartup.select(
      isActivated: true,
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

  @Test func unavailableSelectionDoesNotMutateSuites() {
    let firstSuite = TestDefaults.makeSuite()
    let secondSuite = TestDefaults.makeSuite()
    let firstServer = ServerConfig(id: UUID(), url: "http://first.local", version: .v6)
    let secondServer = ServerConfig(id: UUID(), url: "http://second.local", version: .v6)
    Defaults[.servers(suite: firstSuite)] = [firstServer]
    Defaults[.servers(suite: secondSuite)] = [secondServer]

    let selection = AppStorageStartup.select(
      isActivated: true,
      resolve: { throw AppStorageStartupTestError.resolutionFailed },
      migrate: { _ in Issue.record("Migration must not run") },
      markActivated: { Issue.record("Activation must not change") }
    )

    guard case .unavailable = selection else {
      Issue.record("Expected unavailable storage")
      return
    }
    #expect(Defaults[.servers(suite: firstSuite)].map(\.id) == [firstServer.id])
    #expect(Defaults[.servers(suite: secondSuite)].map(\.id) == [secondServer.id])
  }

  @Test func unavailableDefaultsNeverReadsOrWrites() {
    let suite = UnavailableDefaults()
    let server = ServerConfig(id: UUID(), url: "http://unavailable.local", version: .v6)

    Defaults[.servers(suite: suite)] = [server]
    Defaults[.tempUnblocks(for: server.id, suite: suite)] = [
      TempUnblockRecord(
        domain: "ads.example",
        uuid: UUID().uuidString,
        startDateUTC: Date(timeIntervalSince1970: 1_000),
        durationSeconds: 300
      )
    ]

    #expect(Defaults[.servers(suite: suite)].isEmpty)
    #expect(Defaults[.tempUnblocks(for: server.id, suite: suite)].isEmpty)
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

private enum AppStorageStartupTestError: Error {
  case resolutionFailed
  case migrationFailed
}
