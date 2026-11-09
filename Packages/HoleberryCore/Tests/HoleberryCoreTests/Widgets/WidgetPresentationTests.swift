import Defaults
import Foundation
import Testing

@testable import HoleberryCore

@Suite("WidgetPresentation")
@MainActor
struct WidgetPresentationTests {
  @Test func successfulFetchShowsLiveStatistics() {
    let server = makeServer()
    let checkedAt = Date(timeIntervalSince1970: 2_000)
    let summary = WidgetSummary(
      servers: [server],
      results: [server.id: .success(QuerySummary(totalQueries: 200, totalBlocked: 50))],
      checkedAt: checkedAt
    )

    let presentation = WidgetPresentation(summary: summary, now: checkedAt.addingTimeInterval(10))

    #expect(presentation.health == .allHealthy)
    #expect(
      presentation.content
        == .statistics(
          WidgetQueryStatistics(totalQueries: 200, totalBlocked: 50, observedAt: checkedAt)))
    #expect(presentation.statistics?.totalQueries == 200)
    #expect(presentation.statistics?.totalBlocked == 50)
    #expect(presentation.statistics?.observedAt == checkedAt)
    #expect(presentation.lastCheckedAt == checkedAt)
  }

  @Test func partialFailureIsUnavailable() {
    let first = makeServer(url: "http://first.local")
    let second = makeServer(url: "http://second.local")
    let summary = WidgetSummary(
      servers: [first, second],
      results: [
        first.id: .success(QuerySummary(totalQueries: 1_000, totalBlocked: 500)),
        second.id: .failure(.network("down"))
      ],
      checkedAt: Date(timeIntervalSince1970: 2_000)
    )

    let presentation = WidgetPresentation(summary: summary, now: Date(timeIntervalSince1970: 2_010))

    #expect(presentation.health == .someHealthy)
    #expect(presentation.content == .unavailable)
    #expect(presentation.statistics == nil)
  }

  @Test func totalFailureIsUnavailable() {
    let first = makeServer(url: "http://first.local")
    let second = makeServer(url: "http://second.local")
    let summary = WidgetSummary(
      servers: [first, second],
      results: [first.id: .failure(.network("down")), second.id: .failure(.unauthorized)],
      checkedAt: Date(timeIntervalSince1970: 2_000)
    )

    let presentation = WidgetPresentation(summary: summary, now: Date(timeIntervalSince1970: 2_010))

    #expect(presentation.health == .noneHealthy)
    #expect(presentation.content == .unavailable)
    #expect(presentation.statistics == nil)
  }

  @Test func zeroQueriesShowsZeroPercentStatistics() {
    let server = makeServer()
    let checkedAt = Date(timeIntervalSince1970: 2_000)
    let summary = WidgetSummary(
      servers: [server],
      results: [server.id: .success(QuerySummary(totalQueries: 0, totalBlocked: 0))],
      checkedAt: checkedAt
    )

    let presentation = WidgetPresentation(summary: summary, now: checkedAt.addingTimeInterval(10))

    #expect(presentation.statistics?.blockedPercentage == 0)
    #expect(presentation.statistics?.totalQueries == 0)
  }

  @Test func healthExpiresSixtyMinutesAfterLatestCheck() {
    let server = makeServer()
    let checkedAt = Date(timeIntervalSince1970: 2_000)
    let success = WidgetSummary(
      servers: [server],
      results: [server.id: .success(QuerySummary(totalQueries: 10, totalBlocked: 1))],
      checkedAt: checkedAt
    )
    let failure = WidgetSummary(
      servers: [server],
      results: [server.id: .failure(.network("down"))],
      checkedAt: checkedAt
    )

    #expect(WidgetPresentation(summary: success, now: checkedAt.addingTimeInterval(3_599)).health == .allHealthy)
    #expect(WidgetPresentation(summary: success, now: checkedAt.addingTimeInterval(3_600)).health == .notChecked)
    #expect(WidgetPresentation(summary: failure, now: checkedAt.addingTimeInterval(3_599)).health == .noneHealthy)
    #expect(WidgetPresentation(summary: failure, now: checkedAt.addingTimeInterval(3_600)).health == .notChecked)
  }

  @Test func noCurrentCheckIsUnavailable() {
    let server = makeServer()
    let summary = WidgetSummary(servers: [server], results: [:], checkedAt: nil)

    let presentation = WidgetPresentation(summary: summary, now: Date(timeIntervalSince1970: 1_000))

    #expect(presentation.health == .notChecked)
    #expect(presentation.content == .unavailable)
    #expect(presentation.statistics == nil)
    #expect(presentation.lastCheckedAt == nil)
  }

  @Test func emptyConfigurationIsNoServers() {
    let summary = WidgetSummary(servers: [], results: [:], checkedAt: Date())

    let presentation = WidgetPresentation(summary: summary, now: Date())

    #expect(presentation.content == .noServers)
    #expect(presentation.health == .notChecked)
  }

  @Test func setupRequiredIsGrayAndEmpty() {
    #expect(WidgetPresentation.setupRequired.content == .setupRequired)
    #expect(WidgetPresentation.setupRequired.health == .notChecked)
    #expect(WidgetPresentation.setupRequired.statistics == nil)
    #expect(WidgetPresentation.setupRequired.lastCheckedAt == nil)
  }

  @Test func blockedFractionClampsToRenderableRange() {
    let observedAt = Date(timeIntervalSince1970: 1_000)

    #expect(
      WidgetQueryStatistics(totalQueries: 0, totalBlocked: 0, observedAt: observedAt).blockedFraction == 0
    )
    #expect(
      WidgetQueryStatistics(totalQueries: 100, totalBlocked: 25, observedAt: observedAt).blockedFraction == 0.25
    )
    #expect(
      WidgetQueryStatistics(totalQueries: 100, totalBlocked: 150, observedAt: observedAt).blockedFraction == 1
    )
    #expect(
      WidgetQueryStatistics(totalQueries: 100, totalBlocked: -20, observedAt: observedAt).blockedFraction == 0
    )
  }

  private func makeServer(url: String = "http://pihole.local") -> WidgetServerIdentity {
    WidgetServerIdentity(id: UUID(), url: url, version: .v6)
  }
}

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
